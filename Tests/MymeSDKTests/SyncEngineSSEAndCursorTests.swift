import Testing
import Foundation
@testable import MymeSDK
@testable import MymeSDKTestSupport

/// SyncEngine SSE stream handling: engine lifecycle, event application,
/// cursor resume on reconnect, and the `catchup_too_old` handler (including
/// the actor-reentry concurrency guard).
///
/// Shared helpers live in ``SyncEngineTestKit`` (see SyncEngineTestSupport.swift).
@Suite("SyncEngine SSE and cursor")
struct SyncEngineSSEAndCursorTests {

    @Test("mutation queue is populated on synced-mode writes") func mutationQueueIsPopulatedOnSyncedModeWrites() async throws {
        let (store, queue, _, _, _) = try await SyncEngineTestKit.makeFixture()

        // Simulate synced-mode write: local write + enqueue
        let input = CreateItemInput(type: "core.note", properties: ["body": .string("synced")])
        let item = try await store.createItem(input)
        try await queue.enqueueCreateItem(input, localId: item.id)

        let records = try await queue.fetchAll()
        #expect(records.count == 1)
        #expect(records[0].kind == .createItem)
        #expect(records[0].localId == item.id)
    }

    @Test("SyncEngine start/stop is idempotent") func syncEngineStartStopIsIdempotent() async throws {
        let (_, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        await engine.start()
        await engine.start() // second start is a no-op
        await engine.stop()
        await engine.stop()  // second stop is a no-op
    }

    @Test("SSE item.* events apply to local store") func ssEEventsApplyToLocalStore() async throws {
        let (store, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()

        // Build item.created and item.updated events that together mutate
        // the same server-side item.
        let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        let v1 = Item(
            createdAt: now, id: "server-1",
            properties: ["body": .string("v1")],
            schemaVersion: 1, source: "test", state: .active, tier: .feed,
            timestamp: now, type: "core.note", updatedAt: now, version: 1
        )
        let v2 = Item(
            createdAt: now, id: "server-1",
            properties: ["body": .string("v2")],
            schemaVersion: 1, source: "test", state: .active, tier: .feed,
            timestamp: now, type: "core.note", updatedAt: now, version: 2
        )
        struct ItemPayload: Encodable { let item: Item }
        let enc = JSONEncoder()
        let evt1 = SSEEvent(
            id: "evt-1", event: "item.created",
            data: String(data: try enc.encode(ItemPayload(item: v1)), encoding: .utf8)!
        )
        let evt2 = SSEEvent(
            id: "evt-2", event: "item.updated",
            data: String(data: try enc.encode(ItemPayload(item: v2)), encoding: .utf8)!
        )
        transport.enqueueEvents([evt1, evt2])

        await engine.start()
        // Drive the engine out of `.offline` via the test seam; runLoop
        // opens the SSE stream, drains our events, and finishes.
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.waitUntil(timeout: .milliseconds(500)) {
            (try? await store.fetchItem(id: "server-1"))?.properties["body"] == .string("v2")
        }

        let fetched = try await store.fetchItem(id: "server-1")
        #expect(fetched.properties["body"] == .string("v2"))
        // Cursor should land on the last event.
        let cursor = try await queue.loadSyncState(key: "last_event_id")
        #expect(cursor == "evt-2")
        await engine.stop()
    }

    @Test("opens second SSE stream with Last-Event-ID after reconnect") func cursorResumeOnReconnect() async throws {
        let (_, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()

        // First connection: yield one event then close. Cursor should persist.
        let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        let item = Item(
            createdAt: now, id: "server-rc",
            properties: ["body": .string("hi")],
            schemaVersion: 1, source: "test", state: .active, tier: .feed,
            timestamp: now, type: "core.note", updatedAt: now, version: 1
        )
        struct ItemPayload: Encodable { let item: Item }
        let enc = JSONEncoder()
        let evt = SSEEvent(
            id: "evt-A", event: "item.created",
            data: String(data: try enc.encode(ItemPayload(item: item)), encoding: .utf8)!
        )
        transport.enqueueEvents([evt])
        // Second connection: just close cleanly. We only care about how it's opened.
        transport.enqueueEvents([])

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.waitUntil(timeout: .milliseconds(500)) {
            (try? await queue.loadSyncState(key: "last_event_id")) == "evt-A"
        }

        // Simulate a drop + reconnect.
        await connManager.applyStateForTesting(.offline)
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.waitUntil(timeout: .milliseconds(500)) {
            await transport.calls.filter { $0.path == "/events" }.count >= 2
        }

        let sseCalls = await transport.calls.filter { $0.path == "/events" }
        #expect(sseCalls.count >= 2)
        #expect(sseCalls.first?.lastEventID == nil)            // first call had no cursor
        #expect(sseCalls.last?.lastEventID == "evt-A")         // second call resumes from cursor
        await engine.stop()
    }

    @Test("catchup_too_old clears cursor and triggers full resync")
    func catchupTooOldClearsCursorAndTriggersResync() async throws {
        let (_, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()

        // Seed the cursor as if we'd been running for a while.
        try await queue.saveSyncState(key: "last_event_id", value: "evt-stale")
        #expect(try await queue.loadSyncState(key: "last_event_id") == "evt-stale")

        // First connection: server emits catchup_too_old and closes.
        let catchup = SSEEvent(
            id: nil,
            event: "catchup_too_old",
            data: #"{"type":"catchup_too_old","min_retained_id":100,"requested":50}"#
        )
        transport.enqueueEvents([catchup])
        // performInitialSync will issue a GET /items — return an empty page.
        transport.enqueue(PaginatedResult<ItemWithMetadata>(data: [], cursor: nil, hasMore: false))
        // Second SSE connection after reconnect — empty.
        transport.enqueueEvents([])

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        // Wait for the cursor to be cleared.
        try await SyncEngineTestKit.waitUntil(timeout: .milliseconds(500)) {
            (try? await queue.loadSyncState(key: "last_event_id")) == nil
        }

        // GET /items should have been issued by the resync.
        try await SyncEngineTestKit.waitUntil(timeout: .milliseconds(500)) {
            await transport.calls.contains { $0.path == "/items" && $0.method == .get }
        }

        // Reconnect and assert the new SSE call carries no Last-Event-ID.
        await connManager.applyStateForTesting(.offline)
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.waitUntil(timeout: .milliseconds(500)) {
            await transport.calls.filter { $0.path == "/events" }.count >= 2
        }

        let sseCalls = await transport.calls.filter { $0.path == "/events" }
        #expect(sseCalls.last?.lastEventID == nil)
        await engine.stop()
    }

    @Test("catchup_too_old concurrency guard short-circuits a reentrant call")
    func catchupTooOldConcurrencyGuard() async throws {
        // The `resyncing` guard exists to protect against actor-reentry:
        // if `applyEvent` is suspended inside `performInitialSync()` on
        // a real network call, a second `applyEvent` that enters on the
        // same actor must observe the guard as set and short-circuit.
        //
        // The single SSE for-await loop consumes events serially, so we
        // can't trigger reentry from a single stream in the mock harness.
        // Instead we drive two concurrent `applyEvent` invocations via
        // the internal test seam `_applyEventForTesting` and assert only
        // one `GET /items` is issued.
        let (store, queue, _) = try await MymeSDKTest.makeInMemoryStorePair()
        let transport = BlockingTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )

        try await queue.saveSyncState(key: "last_event_id", value: "evt-stale")

        let catchup = SSEEvent(
            id: nil,
            event: "catchup_too_old",
            data: #"{"type":"catchup_too_old","min_retained_id":100,"requested":50}"#
        )

        // Kick off two concurrent applyEvent calls. The first will take
        // the guard and suspend inside GET /items; the second must see
        // the guard and short-circuit.
        async let first: Void = engine._applyEventForTesting(catchup)
        // Ensure the first has entered the actor and taken the guard.
        try await Task.sleep(for: .milliseconds(20))
        async let second: Void = engine._applyEventForTesting(catchup)

        // Wait for the first to enter GET /items.
        try await SyncEngineTestKit.waitUntil(timeout: .milliseconds(500)) {
            await transport.itemsCallCount >= 1
        }

        // Give the second call time to hit the guard.
        try await Task.sleep(for: .milliseconds(50))

        // Release so the first resync completes.
        await transport.release(
            result: PaginatedResult<ItemWithMetadata>(data: [], cursor: nil, hasMore: false)
        )

        _ = try await (first, second)

        let count = await transport.itemsCallCount
        #expect(count == 1, "expected exactly one resync; got \(count)")
    }
}
