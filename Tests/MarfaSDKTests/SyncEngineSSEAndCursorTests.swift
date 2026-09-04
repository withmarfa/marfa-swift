import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// SyncEngine SSE stream handling: engine lifecycle, event application,
/// cursor resume on reconnect, and the `catchup_too_old` handler (including
/// the actor-reentry concurrency guard).
///
/// Shared helpers live in ``SyncEngineTestKit`` (see SyncEngineTestSupport.swift).
@Suite("SyncEngine SSE and cursor", .timeLimit(.minutes(1)))
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

    @Test("stop during start prevents stale lifecycle task publication")
    func stopDuringStartDoesNotPublishTasks() async throws {
        let (_, _, _, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        await engine.suspendNextStartPublicationForTesting()

        let startTask = Task { await engine.start() }
        try await SyncEngineTestKit.awaitCondition(description: "engine.isStartingForTesting && engine.isStartPublicationSuspendedForTesting") {
            let isStarting = await engine.isStartingForTesting
            let isSuspended = await engine.isStartPublicationSuspendedForTesting
            return isStarting && isSuspended
        }

        await engine.stop()
        #expect(await !engine.isRunningForTesting)
        #expect(await !engine.isStartingForTesting)
        #expect(await !engine.hasLifecycleTasksForTesting)
        #expect(await !connManager.isStartedForTesting)

        await engine.resumeStartPublicationForTesting()
        await startTask.value
        #expect(await !engine.isRunningForTesting)
        #expect(await !engine.hasLifecycleTasksForTesting)
        #expect(await !connManager.isStartedForTesting)

        await engine.start()
        #expect(await engine.isRunningForTesting)
        #expect(await connManager.isStartedForTesting)
        await engine.stop()
    }

    @Test("start waits for an overlapping stop before creating a new lifecycle")
    func startDuringStopRestartsEngine() async throws {
        let (store, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        let transport = BlockingReplayTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        try await queue.enqueueDeleteItem(id: "server-restart")

        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        await transport.waitUntilRequestStarted()

        let stopTask = Task { await engine.stop() }
        try await SyncEngineTestKit.awaitCondition(description: "engine.isStoppingForTesting") {
            await engine.isStoppingForTesting
        }
        let restartTask = Task { await engine.start() }
        await transport.releaseRequest()
        await stopTask.value
        await restartTask.value

        #expect(await engine.isRunningForTesting)
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.awaitCondition(description: "transport.requestCallCount >= 2") {
            await transport.requestCallCount >= 2
        }
        let finalStopTask = Task { await engine.stop() }
        try await SyncEngineTestKit.awaitCondition(description: "engine.isStoppingForTesting") {
            await engine.isStoppingForTesting
        }
        await transport.releaseRequest()
        await finalStopTask.value
    }

    @Test("start cannot open a new lifecycle while a stop is still in flight")
    func startWaitsForTheStopBarrier() async throws {
        let (store, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        let transport = BlockingReplayTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        try await queue.enqueueDeleteItem(id: "server-barrier")

        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        await transport.waitUntilRequestStarted()

        let stopTask = Task { await engine.stop() }
        try await SyncEngineTestKit.awaitCondition(description: "engine.isStoppingForTesting") {
            await engine.isStoppingForTesting
        }

        let restartTask = Task { await engine.start() }
        // The blocked replay holds the barrier open. A start that does not
        // wait for it opens a second lifecycle on top of a teardown that has
        // already snapshotted the first one, so the two overlap: the barrier
        // goes on to stop a ConnectionStateManager the restart just started.
        try await SyncEngineTestKit.expectRemainsFalse(for: .milliseconds(300)) {
            let isStarting = await engine.isStartingForTesting
            let isRunning = await engine.isRunningForTesting
            return isStarting || isRunning
        }

        await transport.releaseRequest()
        await stopTask.value
        await restartTask.value

        #expect(await engine.isRunningForTesting)
        #expect(await connManager.isStartedForTesting)

        await transport.stopBlocking()
        await engine.stop()
    }

    @Test("stop does not return while a reconnect nudge is being installed")
    func stopSweepsAReconnectScheduledDuringTeardown() async throws {
        let (_, _, _, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        await engine.setReconnectDelaysForTesting(base: 0.05, max: 0.05)
        // Widen the window between the `.online` transition and the reconnect
        // nudge. In production it is a couple of actor hops, so a stop landing
        // inside it is invisible to a timing-based test.
        await engine.suspendStreamForTesting(at: .beforeReconnectSchedule)
        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.awaitCondition(description: "engine.isStreamSuspendedForTesting") {
            await engine.isStreamSuspendedForTesting
        }

        let stopTask = Task { await engine.stop() }
        try await SyncEngineTestKit.awaitCondition(description: "engine.isStoppingForTesting") {
            await engine.isStoppingForTesting
        }
        await engine.resumeStreamForTesting()
        await stopTask.value

        // The nudge is an unstructured task: it does not inherit the stream
        // task's cancellation, so one installed after the snapshot outlives
        // the barrier that is supposed to have waited for it.
        #expect(await !engine.hasLifecycleTasksForTesting)
    }

    @Test("a stream closing during teardown does not transition the manager")
    func stoppedStreamDoesNotMarkOnline() async throws {
        let (_, _, _, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        await engine.suspendStreamForTesting(at: .beforeMarkOnline)
        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.awaitCondition(description: "engine.isStreamSuspendedForTesting") {
            await engine.isStreamSuspendedForTesting
        }

        // Opening the stream transitions the manager online, so the count is
        // already non-zero here and the invariant is that teardown adds
        // nothing to it rather than that nothing was ever called.
        let beforeStop = await connManager.markOnlineCallCountForTesting

        let stopTask = Task { await engine.stop() }
        try await SyncEngineTestKit.awaitCondition(description: "engine.isStoppingForTesting") {
            await engine.isStoppingForTesting
        }
        await engine.resumeStreamForTesting()
        await stopTask.value

        // `markOnline` is a no-op once the manager is offline, so the state
        // machine records nothing either way; the call count is what proves
        // the stopped engine kept its hands off a manager it no longer owns.
        #expect(await connManager.markOnlineCallCountForTesting == beforeStop)
    }

    @Test("stop finishes every open event stream")
    func stopFinishesEventStreams() async throws {
        let (_, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        let events = engine.events
        let finished = TestLatch()
        let consumer = Task {
            for await _ in events {}
            await finished.set()
        }

        await engine.start()
        await engine.stop()

        try await SyncEngineTestKit.awaitCondition(description: "finished.isSet") {
            await finished.isSet
        }
        consumer.cancel()
    }

    @Test("subscribing to events registers before the property returns")
    func eventSubscriptionIsSynchronous() async throws {
        let (_, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        // Registering through a task instead lets a stop issued on the next
        // line run first, leaving the new continuation attached to a stopped
        // engine and its consumer awaiting an event that can never arrive.
        // Subscribing from inside the actor pins the observation: a task-based
        // registration would need this actor and so cannot slip in.
        let (stream, count) = await engine.subscribeAndCountForTesting()
        #expect(count == 1)

        await engine.stop()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
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

        try await SyncEngineTestKit.awaitCondition(description: "(try? await store.fetchItem(id: \"server-1\"))?.properties[\"body\"] == .string(\"v2\")"
        ) {
            (try? await store.fetchItem(id: "server-1"))?.properties["body"] == .string("v2")
        }

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

        try await SyncEngineTestKit.awaitCondition(description: "(try? await queue.loadSyncState(key: \"last_event_id\")) == \"evt-A\""
        ) {
            (try? await queue.loadSyncState(key: "last_event_id")) == "evt-A"
        }

        // Simulate a drop + reconnect.
        await connManager.applyStateForTesting(.offline)
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.awaitCondition(description: "transport.calls.filter { $0.path == \"/events\" }.count >= 2"
        ) {
            await transport.calls.filter { $0.path == "/events" }.count >= 2
        }

        let sseCalls = await transport.calls.filter { $0.path == "/events" }
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
        // performInitialSync issues a GET /items and then a GET /edges — return
        // an empty page for each.
        transport.enqueue(PaginatedResult<ItemWithMetadata>(data: [], cursor: nil, hasMore: false))
        transport.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))
        // Second SSE connection after reconnect — empty.
        transport.enqueueEvents([])

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        // Wait for the cursor to be cleared.
        try await SyncEngineTestKit.awaitCondition(description: "(try? await queue.loadSyncState(key: \"last_event_id\")) == nil"
        ) {
            (try? await queue.loadSyncState(key: "last_event_id")) == nil
        }

        // GET /items should have been issued by the resync.
        try await SyncEngineTestKit.awaitCondition(description: "transport.calls.contains an /items GET") {
            await transport.calls.contains { $0.path == "/items" && $0.method == .get }
        }

        // Reconnect and assert the new SSE call carries no Last-Event-ID.
        await connManager.applyStateForTesting(.offline)
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.awaitCondition(description: "transport.calls.filter { $0.path == \"/events\" }.count >= 2"
        ) {
            await transport.calls.filter { $0.path == "/events" }.count >= 2
        }

        let sseCalls = await transport.calls.filter { $0.path == "/events" }
        #expect(sseCalls.last?.lastEventID == nil)
        await engine.stop()
    }

    @Test("catchup_too_old concurrency guard short-circuits a reentrant call")
    func catchupTooOldConcurrencyGuard() async throws {
        // Two retention-gap events landing on actor reentry must produce one
        // import between them. The engine publishes the import into a shared
        // slot before its first suspension point, so the second call finds it
        // and joins rather than paging the library again beside the first.
        //
        // The single SSE for-await loop consumes events serially, so reentry
        // cannot be triggered from one stream in the mock harness. Instead we
        // drive two concurrent `applyEvent` invocations via the internal test
        // seam `_applyEventForTesting` and assert only one `GET /items` is
        // issued.
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
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

        // Wait for a signal instead of for a duration. The first call is
        // inside GET /items exactly when the transport has been asked for
        // items, and taking the guard is what got it there — so this observes
        // the fact the sleep was estimating, and starting the second before it
        // holds is no longer possible on a slow machine.
        try await SyncEngineTestKit.awaitCondition(
            description: "the first call to reach GET /items holding the guard"
        ) {
            await transport.itemsCallCount >= 1
        }

        async let second: Void = engine._applyEventForTesting(catchup)

        // The second must short-circuit on the guard rather than issue its own
        // request. That is a negative, so it needs a window, and there is no
        // constant to derive one from — the quantity is a few actor hops. It
        // is stated as what it is rather than dressed as a readiness gate:
        // long enough that a second request would have landed, and paid in
        // full only on the passing path.
        try await SyncEngineTestKit.expectRemainsFalse(for: .milliseconds(200)) {
            await transport.itemsCallCount > 1
        }

        // Release so the first resync completes.
        await transport.release(
            result: PaginatedResult<ItemWithMetadata>(data: [], cursor: nil, hasMore: false)
        )

        _ = await (first, second)

        let count = await transport.itemsCallCount
        #expect(count == 1, "expected exactly one resync; got \(count)")
    }
}
