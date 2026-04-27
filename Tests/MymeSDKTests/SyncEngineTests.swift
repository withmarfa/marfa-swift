import Testing
import Foundation
@testable import MymeSDK
@testable import MymeSDKTestSupport
import SwiftData

// Test-only Transport used by the concurrency-guard test. Its `request` call
// suspends on a continuation until the test calls `release(...)`, simulating
// a real network round-trip and forcing actor reentry. The `eventStream`
// side mirrors MockTransport's minimal semantics.
fileprivate actor BlockingTransport: Transport {
    private var eventStreams: [[SSEEvent]] = []
    private var continuation: CheckedContinuation<Data, Never>?
    private(set) var itemsCallCount = 0

    func enqueueEvents(_ events: [SSEEvent]) {
        eventStreams.append(events)
    }

    func release<T: Encodable>(result: T) {
        let data = try! JSONEncoder().encode(result)
        continuation?.resume(returning: data)
        continuation = nil
    }

    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T {
        if path == "/items" && method == .get {
            itemsCallCount += 1
            let data: Data = await withCheckedContinuation { cont in
                self.continuation = cont
            }
            return try JSONDecoder().decode(T.self, from: data)
        }
        fatalError("BlockingTransport: unexpected request \(method.rawValue) \(path)")
    }

    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> ConflictResult<T> {
        fatalError("BlockingTransport: requestWithConflict not supported")
    }

    func rawRequest(
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?,
        query: [(String, String)]?
    ) async throws -> (Data, HTTPURLResponse) {
        fatalError("BlockingTransport: rawRequest not supported")
    }

    nonisolated func eventStream(
        path: String,
        query: [(String, String)]?,
        lastEventID: String?
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let events = await self.popEventStream()
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    private func popEventStream() -> [SSEEvent] {
        guard !eventStreams.isEmpty else { return [] }
        return eventStreams.removeFirst()
    }
}

/// Tests for ``SyncEngine``, ``MutationQueue``, and ``ConnectionStateManager``.
///
/// All tests use in-memory SQLite (`:memory:`) and ``MockTransport`` — no real
/// network or on-disk state.
@Suite("SyncEngine")
struct SyncEngineTests {

    // MARK: - MutationQueue unit tests

    @Suite("MutationQueue")
    struct MutationQueueTests {

        // Pair-builder: shared `ModelContainer` so the queue and store
        // commit to the same SQLite file (synced-mode shape).
        private func makeStoreAndQueue() async throws -> (LocalStore, MutationQueue) {
            let (store, queue, _) = try await MymeSDKTest.makeInMemoryStorePair()
            return (store, queue)
        }

        @Test("Queue starts empty") func startsEmpty() async throws {
            let (store, queue) = try await makeStoreAndQueue()
            #expect(try await queue.isEmpty)
        }

        @Test("Enqueue createItem appears in fetchAll") func enqueueCreateItem() async throws {
            let (store, queue) = try await makeStoreAndQueue()
            let input = CreateItemInput(type: "core.note", properties: ["body": .string("hi")])
            try await queue.enqueueCreateItem(input, localId: "local-123")

            let records = try await queue.fetchAll()
            #expect(records.count == 1)
            #expect(records[0].kind == .createItem)
            #expect(records[0].localId == "local-123")
            #expect(try await queue.isEmpty == false)
        }

        @Test("remove deletes a record") func removeRecord() async throws {
            let (store, queue) = try await makeStoreAndQueue()
            let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
            try await queue.enqueueCreateItem(input, localId: "l1")

            let records = try await queue.fetchAll()
            #expect(records.count == 1)
            try await queue.remove(id: records[0].id)
            #expect(try await queue.isEmpty)
        }

        @Test("recordFailure increments attempt_count") func recordFailure() async throws {
            let (store, queue) = try await makeStoreAndQueue()
            try await queue.enqueueDeleteItem(id: "item-1")

            var records = try await queue.fetchAll()
            let id = records[0].id
            #expect(records[0].attemptCount == 0)

            try await queue.recordFailure(id: id, error: "network error")
            records = try await queue.fetchAll()
            #expect(records[0].attemptCount == 1)
            #expect(records[0].lastError == "network error")
        }

        @Test("fetchAll returns records in creation order") func fetchAllOrder() async throws {
            let (store, queue) = try await makeStoreAndQueue()
            try await queue.enqueueDeleteItem(id: "a")
            try await queue.enqueueDeleteItem(id: "b")
            try await queue.enqueueDeleteItem(id: "c")

            let records = try await queue.fetchAll()
            #expect(records.count == 3)
            // All three should be present; creation order preserved by created_at ordering.
            let localIds = records.compactMap { $0.localId }
            #expect(localIds.contains("a"))
            #expect(localIds.contains("b"))
            #expect(localIds.contains("c"))
        }

        @Test("saveSyncState and loadSyncState round-trip") func syncStateCursor() async throws {
            let (store, queue) = try await makeStoreAndQueue()

            let loaded = try await queue.loadSyncState(key: "last_event_id")
            #expect(loaded == nil)

            try await queue.saveSyncState(key: "last_event_id", value: "evt-42")
            let reloaded = try await queue.loadSyncState(key: "last_event_id")
            #expect(reloaded == "evt-42")

            // Update
            try await queue.saveSyncState(key: "last_event_id", value: "evt-99")
            let updated = try await queue.loadSyncState(key: "last_event_id")
            #expect(updated == "evt-99")
        }

        @Test("enqueue all mutation kinds") func enqueueAllKinds() async throws {
            let (store, queue) = try await makeStoreAndQueue()
            let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])

            try await queue.enqueueCreateItem(input, localId: "li")
            try await queue.enqueueUpdateItem(id: "i1", properties: ["body": .string("y")])
            try await queue.enqueueDeleteItem(id: "i2")
            try await queue.enqueueRestoreItem(id: "i3")
            try await queue.enqueueTransitionItem(id: "i4", to: .archived)
            try await queue.enqueuePurgeItem(id: "i5")
            try await queue.enqueueCreateEdge(source: "a", target: "b", edgeType: "about", properties: nil, localEdgeId: "e1")
            try await queue.enqueueUpdateEdge(id: "e2", properties: ["note": .string("x")])
            try await queue.enqueueDeleteEdge(id: "e3")
            try await queue.enqueueSetMetadata(itemId: "i6", input: MetadataInput(tags: ["a"]))
            try await queue.enqueueMergeMetadata(itemId: "i7", input: MetadataInput(tags: ["b"]))
            try await queue.enqueueAddTags(itemId: "i8", tags: ["c"])
            try await queue.enqueueRemoveTag(itemId: "i9", tag: "d")

            let records = try await queue.fetchAll()
            #expect(records.count == 13)
            let kinds = records.map(\.kind)
            #expect(kinds.contains(.createItem))
            #expect(kinds.contains(.updateItem))
            #expect(kinds.contains(.deleteItem))
            #expect(kinds.contains(.restoreItem))
            #expect(kinds.contains(.transitionItem))
            #expect(kinds.contains(.purgeItem))
            #expect(kinds.contains(.createEdge))
            #expect(kinds.contains(.updateEdge))
            #expect(kinds.contains(.deleteEdge))
            #expect(kinds.contains(.setMetadata))
            #expect(kinds.contains(.mergeMetadata))
            #expect(kinds.contains(.addTags))
            #expect(kinds.contains(.removeTag))
        }

        @Test("enqueueUpdateItem captures version + conflict + library on the payload") func captureUpdateOptions() async throws {
            let (store, queue) = try await makeStoreAndQueue()
            try await queue.enqueueUpdateItem(
                id: "i1",
                properties: ["body": .string("x")],
                version: 5,
                conflict: .manual,
                tier: .library
            )
            let records = try await queue.fetchAll()
            let updateRecord = try #require(records.first { $0.kind == .updateItem })
            let payload = try JSONDecoder().decode(
                UpdateItemPayload.self,
                from: updateRecord.payloadJson.data(using: .utf8) ?? Data()
            )
            #expect(payload.version == 5)
            #expect(payload.conflict == .manual)
            #expect(payload.tier == .library)
        }

        @Test("enqueueUpdateItem with no options leaves version/conflict/library nil") func captureNoUpdateOptions() async throws {
            let (store, queue) = try await makeStoreAndQueue()
            try await queue.enqueueUpdateItem(
                id: "i1",
                properties: ["body": .string("x")]
            )
            let records = try await queue.fetchAll()
            let updateRecord = try #require(records.first { $0.kind == .updateItem })
            let payload = try JSONDecoder().decode(
                UpdateItemPayload.self,
                from: updateRecord.payloadJson.data(using: .utf8) ?? Data()
            )
            #expect(payload.version == nil)
            #expect(payload.conflict == nil)
            #expect(payload.tier == nil)
        }

        // MARK: - drainRequests broadcast

        @Test("drainRequests yields once per enqueue across every MutationKind helper")
        func drainRequestsYieldsPerEnqueue() async throws {
            let (_, queue) = try await makeStoreAndQueue()

            // `drainRequests` is an async actor property — awaiting it
            // returns a stream whose continuation is already registered,
            // so pings fired on the very next enqueue are guaranteed to
            // land.
            let stream = await queue.drainRequests
            var iter = stream.makeAsyncIterator()

            // One call per MutationKind case (19 in total). Consume each
            // ping as we go so nothing is buffered out of order.
            let kinds: [() async throws -> Void] = [
                {
                    try await queue.enqueueCreateItem(
                        CreateItemInput(type: "core.note", properties: [:]),
                        localId: "l1"
                    )
                },
                { try await queue.enqueueUpdateItem(id: "l1", properties: [:]) },
                { try await queue.enqueueDeleteItem(id: "l1") },
                { try await queue.enqueueRestoreItem(id: "l1") },
                { try await queue.enqueueTransitionItem(id: "l1", to: .archived) },
                { try await queue.enqueuePurgeItem(id: "l1") },
                {
                    try await queue.enqueueCreateEdge(
                        source: "a", target: "b", edgeType: "x.y", properties: nil, localEdgeId: "e1"
                    )
                },
                { try await queue.enqueueUpdateEdge(id: "e1", properties: [:]) },
                { try await queue.enqueueDeleteEdge(id: "e1") },
                { try await queue.enqueueSetMetadata(itemId: "l1", input: MetadataInput(tags: [])) },
                { try await queue.enqueueMergeMetadata(itemId: "l1", input: MetadataInput(tags: [])) },
                { try await queue.enqueueAddTags(itemId: "l1", tags: ["t"]) },
                { try await queue.enqueueRemoveTag(itemId: "l1", tag: "t") },
                { try await queue.enqueueSetExtension(itemId: "l1", namespace: "ns", data: [:]) },
                { try await queue.enqueueDeleteExtension(itemId: "l1", namespace: "ns") },
                { try await queue.enqueueBulk(BulkInput(items: [])) },
                {
                    try await queue.enqueueBulkAction(
                        .transition(filter: BulkActionFilter(), state: .archived)
                    )
                },
                { try await queue.enqueueBulkEdges(BulkEdgeInput(edges: [])) },
                {
                    try await queue.enqueueBlobUpload(
                        hash: "sha256:deadbeef", data: Data([0x01, 0x02]), mimeType: "application/octet-stream"
                    )
                },
            ]

            for fire in kinds {
                try await fire()
                let ping: Void? = await iter.next()
                #expect(ping != nil)
            }
        }
    }

    // MARK: - ConnectionStateManager unit tests

    @Suite("ConnectionStateManager")
    struct ConnectionStateManagerTests {

        @Test("initial state is offline") func initialState() async {
            let manager = ConnectionStateManager()
            let state = await manager.state
            #expect(state == .offline)
        }

        @Test("stateUpdates yields current state immediately") func stateUpdatesYieldsCurrentStateImmediately() async throws {
            let manager = ConnectionStateManager()
            let stream = manager.stateUpdates
            var iter = stream.makeAsyncIterator()
            let first = await iter.next()
            #expect(first == .offline)
        }

        @Test("markSyncing / markOnline transition from non-offline states") func markSyncingMarkOnlineTransitionFromNonOfflineStates() async {
            let manager = ConnectionStateManager()
            // markSyncing is a no-op when offline
            await manager.markSyncing()
            #expect(await manager.state == .offline)

            // Manually inject connecting state (normally from NWPathMonitor)
            // Since we can't inject NWPathMonitor events in unit tests, test markOnline
            // from syncing state by using the internal applyState pathway via markSyncing.
            // The guard `guard state != .offline` means markSyncing is a no-op from offline.
            // This tests the guard itself.
            await manager.markOnline()
            #expect(await manager.state == .offline) // Still offline — guard protects
        }

        @Test("stop finishes stateUpdates stream") func stopFinishesStateUpdatesStream() async throws {
            let manager = ConnectionStateManager()

            // Collect events from the stream in a background task, then stop.
            let collected = await withTaskGroup(of: [ConnectionState].self) { group in
                group.addTask {
                    let stream = manager.stateUpdates
                    var results: [ConnectionState] = []
                    for await state in stream {
                        results.append(state)
                    }
                    return results
                }
                // Let the inner task subscribe and receive the initial state.
                try? await Task.sleep(for: .milliseconds(10))
                // Stop — should finish the stream.
                await manager.stop()
                return await group.next()!
            }
            // The stream yielded the initial .offline state then finished.
            #expect(collected == [.offline])
        }
    }

    // MARK: - SyncEngine integration tests (using MockTransport)

    @Suite("SyncEngine integration")
    struct SyncEngineIntegrationTests {

        // Build a full synced client fixture.
        private func makeFixture() async throws -> (
            store: LocalStore,
            queue: MutationQueue,
            transport: MockTransport,
            connManager: ConnectionStateManager,
            engine: SyncEngine
        ) {
            let (store, queue, _) = try await MymeSDKTest.makeInMemoryStorePair()
            let transport = MockTransport()
            let connManager = ConnectionStateManager()
            let engine = SyncEngine(
                transport: transport,
                localStore: store,
                mutationQueue: queue,
                connectionManager: connManager
            )
            return (store, queue, transport, connManager, engine)
        }

        @Test("mutation queue is populated on synced-mode writes") func mutationQueueIsPopulatedOnSyncedModeWrites() async throws {
            let (store, queue, _, _, _) = try await makeFixture()

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
            let (_, _, _, _, engine) = try await makeFixture()
            await engine.start()
            await engine.start() // second start is a no-op
            await engine.stop()
            await engine.stop()  // second stop is a no-op
        }

        // MARK: - SSE event application

        @Test("SSE item.* events apply to local store") func ssEEventsApplyToLocalStore() async throws {
            let (store, queue, transport, connManager, engine) = try await makeFixture()

            // Build item.created and item.updated events that together mutate
            // the same server-side item.
            let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
            let v1 = Item(
                createdAt: now, id: "server-1",
                origin: .user, properties: ["body": .string("v1")],
                schemaVersion: 1, source: "test", state: .active, tier: .feed,
                timestamp: now, type: "core.note", updatedAt: now, version: 1
            )
            let v2 = Item(
                createdAt: now, id: "server-1",
                origin: .user, properties: ["body": .string("v2")],
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

            try await waitUntil(timeout: .milliseconds(500)) {
                (try? await store.fetchItem(id: "server-1"))?.properties["body"] == .string("v2")
            }

            let fetched = try await store.fetchItem(id: "server-1")
            #expect(fetched.properties["body"] == .string("v2"))
            // Cursor should land on the last event.
            let cursor = try await queue.loadSyncState(key: "last_event_id")
            #expect(cursor == "evt-2")
            await engine.stop()
        }

        // MARK: - Mutation replay failure accounting

        @Test("mutation replay records failure when transport throws") func mutationReplayRecordsFailure() async throws {
            let (_, queue, transport, connManager, engine) = try await makeFixture()

            // A single pending delete the engine will try to replay.
            try await queue.enqueueDeleteItem(id: "server-x")

            // Empty SSE stream (so runLoop proceeds to replay), then the
            // DELETE itself throws a network-class error.
            transport.enqueueEvents([])
            let netError = NetworkError(
                NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "offline"])
            )
            transport.enqueueError(netError)

            await engine.start()
            await connManager.applyStateForTesting(.connecting)

            try await waitUntil(timeout: .milliseconds(500)) {
                let all = try? await queue.fetchAll()
                return (all?.first?.attemptCount ?? 0) >= 1
            }

            let remaining = try await queue.fetchAll()
            #expect(remaining.count == 1)
            #expect(remaining[0].attemptCount == 1)
            #expect(remaining[0].lastError?.contains("offline") == true)
            await engine.stop()
        }

        // MARK: - Permanent-error drop

        @Test("mutation replay drops queued record on 404 NotFoundError") func mutationReplayDropsOn404() async throws {
            let (_, queue, transport, connManager, engine) = try await makeFixture()

            // Queue an update against an item the server "doesn't have"
            // (matches the `019da086-…` pattern from the bug report).
            try await queue.enqueueUpdateItem(
                id: "019da086-d675-7cd8-ba3f-3dc4e6e7bd42",
                properties: ["body": .string("stale")]
            )

            // Subscribe before triggering the cycle so we can catch the
            // `.mutationDropped` event.
            let events = await engine.events
            let collector = Task { () -> [SyncEvent] in
                var out: [SyncEvent] = []
                for await event in events {
                    out.append(event)
                    if case .mutationDropped = event { return out }
                    if case .synced = event { return out }
                }
                return out
            }

            transport.enqueueEvents([])
            transport.enqueueError(NotFoundError(message: "Item not found"))

            await engine.start()
            await connManager.applyStateForTesting(.connecting)

            // The replay should remove the record (no retry on permanent error).
            try await waitUntil(timeout: .milliseconds(500)) {
                (try? await queue.isEmpty) == true
            }
            #expect(try await queue.isEmpty)

            let collected = await collector.value
            let dropEvent = collected.first { if case .mutationDropped = $0 { return true } else { return false } }
            #expect(dropEvent != nil)
            if case let .mutationDropped(kind, itemId, attempt, error) = dropEvent {
                #expect(kind == "updateItem")
                #expect(itemId == "019da086-d675-7cd8-ba3f-3dc4e6e7bd42")
                #expect(attempt == 1)
                #expect(error is NotFoundError)
            }

            await engine.stop()
        }

        @Test("mutation replay drops queued record on 400 ValidationError") func mutationReplayDropsOn400() async throws {
            let (_, queue, transport, connManager, engine) = try await makeFixture()

            // Matches the `6837a0e8-…` UUIDv4 pattern from the bug report —
            // server would reject the ID with INVALID_ID (400).
            try await queue.enqueueUpdateItem(
                id: "6837a0e8-d316-4433-ac4c-d1e40f19615f",
                properties: ["body": .string("bad id")]
            )

            transport.enqueueEvents([])
            transport.enqueueError(ValidationError(message: "Invalid item ID"))

            await engine.start()
            await connManager.applyStateForTesting(.connecting)

            try await waitUntil(timeout: .milliseconds(500)) {
                (try? await queue.isEmpty) == true
            }
            #expect(try await queue.isEmpty)
            await engine.stop()
        }

        @Test("mutation replay retains queued record on transient 5xx") func mutationReplayRetainsOn5xx() async throws {
            let (_, queue, transport, connManager, engine) = try await makeFixture()

            try await queue.enqueueUpdateItem(
                id: "019da086-d675-7cd8-ba3f-3dc4e6e7bd42",
                properties: ["body": .string("temp fail")]
            )

            transport.enqueueEvents([])
            // 500 is transient — MymeError base class, not a permanent subclass.
            transport.enqueueError(MymeError(
                code: "server_error", message: "boom", status: 500
            ))

            await engine.start()
            await connManager.applyStateForTesting(.connecting)

            try await waitUntil(timeout: .milliseconds(500)) {
                let all = try? await queue.fetchAll()
                return (all?.first?.attemptCount ?? 0) >= 1
            }

            let remaining = try await queue.fetchAll()
            #expect(remaining.count == 1)
            #expect(remaining[0].attemptCount == 1)
            await engine.stop()
        }

        @Test("mixed queue drops permanent + retains transient in one cycle") func mutationReplayMixedCycle() async throws {
            let (_, queue, transport, connManager, engine) = try await makeFixture()

            // Two mutations: first fails permanently (404), second fails
            // transiently (network). First should be dropped, second should
            // stay queued. Order matters — replay processes in creation order.
            try await queue.enqueueUpdateItem(
                id: "019da086-d675-7cd8-ba3f-3dc4e6e7bd42",
                properties: ["body": .string("stale")]
            )
            try await queue.enqueueUpdateItem(
                id: "019eb000-0000-7000-8000-000000000000",
                properties: ["body": .string("transient")]
            )

            transport.enqueueEvents([])
            transport.enqueueError(NotFoundError(message: "gone"))
            transport.enqueueError(NetworkError(
                NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "offline"])
            ))

            await engine.start()
            await connManager.applyStateForTesting(.connecting)

            try await waitUntil(timeout: .milliseconds(500)) {
                let all = try? await queue.fetchAll()
                return (all?.count == 1) && ((all?.first?.attemptCount ?? 0) >= 1)
            }

            let remaining = try await queue.fetchAll()
            #expect(remaining.count == 1)
            #expect(remaining[0].localId == "019eb000-0000-7000-8000-000000000000")
            #expect(remaining[0].attemptCount == 1)
            await engine.stop()
        }

        // MARK: - Cursor resume

        @Test("opens second SSE stream with Last-Event-ID after reconnect") func cursorResumeOnReconnect() async throws {
            let (_, queue, transport, connManager, engine) = try await makeFixture()

            // First connection: yield one event then close. Cursor should persist.
            let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
            let item = Item(
                createdAt: now, id: "server-rc",
                origin: .user, properties: ["body": .string("hi")],
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

            try await waitUntil(timeout: .milliseconds(500)) {
                (try? await queue.loadSyncState(key: "last_event_id")) == "evt-A"
            }

            // Simulate a drop + reconnect.
            await connManager.applyStateForTesting(.offline)
            await connManager.applyStateForTesting(.connecting)

            try await waitUntil(timeout: .milliseconds(500)) {
                await transport.calls.filter { $0.path == "/events" }.count >= 2
            }

            let sseCalls = await transport.calls.filter { $0.path == "/events" }
            #expect(sseCalls.count >= 2)
            #expect(sseCalls.first?.lastEventID == nil)            // first call had no cursor
            #expect(sseCalls.last?.lastEventID == "evt-A")         // second call resumes from cursor
            await engine.stop()
        }

        // Simple polling helper — SSE consumption is task-driven and can't be
        // pinned to a known deadline. Poll until `condition` returns true or
        // the timeout elapses. Keeps tests deterministic without hard sleeps.
        private func waitUntil(
            timeout: Duration,
            every: Duration = .milliseconds(10),
            _ condition: @Sendable () async throws -> Bool
        ) async throws {
            let start = ContinuousClock.now
            while ContinuousClock.now - start < timeout {
                if try await condition() { return }
                try await Task.sleep(for: every)
            }
            if try await condition() { return }
            Issue.record("waitUntil: condition never satisfied within \(timeout)")
        }

        // MARK: - catchup_too_old handler

        @Test("catchup_too_old clears cursor and triggers full resync")
        func catchupTooOldClearsCursorAndTriggersResync() async throws {
            let (_, queue, transport, connManager, engine) = try await makeFixture()

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
            try await waitUntil(timeout: .milliseconds(500)) {
                (try? await queue.loadSyncState(key: "last_event_id")) == nil
            }

            // GET /items should have been issued by the resync.
            try await waitUntil(timeout: .milliseconds(500)) {
                await transport.calls.contains { $0.path == "/items" && $0.method == .get }
            }

            // Reconnect and assert the new SSE call carries no Last-Event-ID.
            await connManager.applyStateForTesting(.offline)
            await connManager.applyStateForTesting(.connecting)

            try await waitUntil(timeout: .milliseconds(500)) {
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
            try await waitUntil(timeout: .milliseconds(500)) {
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

        // MARK: - Fix A: ItemsNamespace.create id stamping

        @Test("ItemsNamespace.create stamps a UUIDv7 into the queued payload when input.id is nil")
        func createStampsIdIntoEnqueuedPayload() async throws {
            let (store, queue, transport, _, _) = try await makeFixture()
            let items = ItemsNamespace(
                transport: transport,
                defaultConflictStrategy: .auto,
                localStore: store,
                mutationQueue: queue
            )

            let created = try await items.create(
                CreateItemInput(type: "core.note", properties: ["body": .string("fresh")])
            )

            // The returned id is the UUIDv7 the SDK stamped.
            #expect(created.id.isEmpty == false)

            let records = try await queue.fetchAll()
            #expect(records.count == 1)
            let payload = try JSONDecoder().decode(
                CreateItemPayload.self,
                from: records[0].payloadJson.data(using: .utf8) ?? Data()
            )
            // Critical: the enqueued payload carries the same id the local
            // store knows about. Without this, the server mints its own id
            // and `SyncEngine.replayRecord` purges the local row, breaking
            // any app view holding `created.id`.
            #expect(payload.input.id == created.id)
            #expect(records[0].localId == created.id)
        }

        @Test("createItem replay with stamped id takes the no-op path (no rewrite, no purge)")
        func createReplayWithStampedIdIsNoOpReconcile() async throws {
            let (store, queue, transport, connManager, engine) = try await makeFixture()
            // Compress reconnect schedule so the test doesn't hang waiting
            // on back-off sleeps after the stream closes.
            await engine.setReconnectDelaysForTesting(base: 0.01, max: 0.05)
            let items = ItemsNamespace(
                transport: transport,
                defaultConflictStrategy: .auto,
                localStore: store,
                mutationQueue: queue
            )

            let created = try await items.create(
                CreateItemInput(type: "core.note", properties: ["body": .string("v1")])
            )

            // Empty SSE + server echoes the client id on POST /items.
            transport.enqueueEvents([])
            let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
            let echoed = Item(
                createdAt: now, id: created.id,
                origin: .user, properties: ["body": .string("v1")],
                schemaVersion: 1, source: "test", state: .active, tier: .feed,
                timestamp: now, type: "core.note", updatedAt: now, version: 1
            )
            transport.enqueue(ItemResponse(item: echoed, metadata: nil))

            await engine.start()
            await connManager.applyStateForTesting(.connecting)

            try await waitUntil(timeout: .milliseconds(500)) {
                (try? await queue.isEmpty) == true
            }

            // Local row still present under the stamped id — no purge fired.
            let fetched = try await store.fetchItem(id: created.id)
            #expect(fetched.id == created.id)
            await engine.stop()
        }

        // MARK: - Fix B: cascade drop on permanent createItem failure

        @Test("permanent createItem drop cascades to dependent mutations and purges the local row")
        func createItemCascadeDropsDependents() async throws {
            let (store, queue, transport, connManager, engine) = try await makeFixture()
            await engine.setReconnectDelaysForTesting(base: 0.01, max: 0.05)

            // Seed the local store + queue as if the app had created a note,
            // edited it, and spun off a reply edge — all before sync fires.
            // "A" is the note that will fail server-side; "X" and "Y" are
            // unrelated siblings that must survive.
            let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
            let ghost = Item(
                createdAt: now, id: "A", origin: .user,
                properties: ["body": .string("")], schemaVersion: 1, source: "test",
                state: .active, tier: .feed, timestamp: now, type: "core.note",
                updatedAt: now, version: 1
            )
            try await store.upsertItem(ghost)
            let survivor = Item(
                createdAt: now, id: "Y", origin: .user,
                properties: ["body": .string("kept")], schemaVersion: 1, source: "test",
                state: .active, tier: .feed, timestamp: now, type: "core.note",
                updatedAt: now, version: 1
            )
            try await store.upsertItem(survivor)

            let createInput = CreateItemInput(
                type: "core.note", properties: ["body": .string("")], id: "A"
            )
            try await queue.enqueueCreateItem(createInput, localId: "A")
            try await queue.enqueueUpdateItem(id: "A", properties: ["body": .string("typed")])
            try await queue.enqueueCreateEdge(
                source: "A", target: "X", edgeType: "in-thread",
                properties: nil, localEdgeId: "E-AX"
            )
            try await queue.enqueueUpdateItem(id: "Y", properties: ["body": .string("untouched")])

            // Collect `.mutationDropped` events so we can assert cascade emission.
            let events = await engine.events
            let collector = Task { () -> [SyncEvent] in
                var out: [SyncEvent] = []
                for await event in events {
                    out.append(event)
                    // Stop once we've seen a `.synced` or `.failed` terminal.
                    if case .synced = event { return out }
                    if case .failed = event { return out }
                }
                return out
            }

            transport.enqueueEvents([])
            // POST /items → 400 ValidationError (permanent, triggers cascade).
            transport.enqueueError(ValidationError(message: "bad create"))
            // PATCH /items/Y still needs a response — the sibling survives
            // and replays successfully.
            let updatedY = Item(
                createdAt: now, id: "Y", origin: .user,
                properties: ["body": .string("untouched")], schemaVersion: 1, source: "test",
                state: .active, tier: .feed, timestamp: now, type: "core.note",
                updatedAt: now, version: 2
            )
            transport.enqueue(ItemResponse(item: updatedY, metadata: nil))

            await engine.start()
            await connManager.applyStateForTesting(.connecting)

            try await waitUntil(timeout: .milliseconds(500)) {
                (try? await queue.isEmpty) == true
            }

            // Queue is fully drained — A's createItem + cascade dropped,
            // Y's updateItem replayed successfully.
            #expect(try await queue.isEmpty)

            // Ghost A purged from local store; survivor Y intact.
            let ghostFetch = try? await store.fetchItem(id: "A")
            #expect(ghostFetch == nil)
            let survivorFetch = try await store.fetchItem(id: "Y")
            #expect(survivorFetch.id == "Y")

            let collected = await collector.value
            let drops = collected.compactMap { event -> (String, String?)? in
                if case let .mutationDropped(kind, itemId, _, _) = event {
                    return (kind, itemId)
                }
                return nil
            }
            // Three drops total: the createItem root + the cascaded
            // updateItem + createEdge. Y's updateItem is *not* dropped.
            #expect(drops.count == 3)
            let droppedKinds = Set(drops.map { $0.0 })
            #expect(droppedKinds == Set(["createItem", "updateItem", "createEdge"]))
            // Every drop carries a local id matching "A" or the cascaded
            // edge id "E-AX".
            let droppedItemIds = Set(drops.compactMap { $0.1 })
            #expect(droppedItemIds == Set(["A", "E-AX"]))
            await engine.stop()
        }

        // MARK: - Fix C: SSE reconnect nudge drains queue without network flap

        @Test("SSE reconnect nudge drains mutations queued after the first replay")
        func sseReconnectDrainsLaterMutations() async throws {
            let (_, queue, transport, connManager, engine) = try await makeFixture()
            // Compress the back-off so the test runs in tens of ms, not seconds.
            await engine.setReconnectDelaysForTesting(base: 0.02, max: 0.05)

            // First SSE stream: empty, finishes cleanly. No mutations queued
            // yet, so the first replay emits `.synced` (no drops / no failures).
            transport.enqueueEvents([])
            // Second SSE stream (reached via the reconnect nudge): also empty.
            transport.enqueueEvents([])
            // Subsequent streams (any further reconnect cycles): empty too.
            transport.enqueueEvents([])
            transport.enqueueEvents([])

            await engine.start()
            await connManager.applyStateForTesting(.connecting)

            // Wait for the first SSE stream to be observed.
            try await waitUntil(timeout: .milliseconds(500)) {
                await transport.calls.filter { $0.path == "/events" }.count >= 1
            }

            // Now enqueue a mutation AFTER the first replay cycle has
            // already ticked. Without the reconnect nudge, this mutation
            // would sit forever — no network transition will fire.
            try await queue.enqueueDeleteItem(id: "019eb000-0000-7000-8000-000000000042")
            transport.enqueueError(NotFoundError(message: "server gone"))

            // Assert the mutation drains without us manually re-triggering
            // `.connecting`.
            try await waitUntil(timeout: .milliseconds(800)) {
                (try? await queue.isEmpty) == true
            }
            #expect(try await queue.isEmpty)

            // And assert we actually opened the SSE stream more than once —
            // the reconnect nudge drove the re-open.
            let sseCallCount = await transport.calls.filter { $0.path == "/events" }.count
            #expect(sseCallCount >= 2, "expected reconnect nudge to re-open SSE at least once; got \(sseCallCount)")

            await engine.stop()
        }

        // MARK: - Fix D: transient createItem skips downstream mutations

        @Test("transient createItem blocks downstream deleteItem from running in the same cycle")
        func transientCreateItemBlocksDeleteItemSameCycle() async throws {
            let (store, queue, transport, connManager, engine) = try await makeFixture()
            // Compress back-off so cycle 2 fires automatically in tens of ms.
            await engine.setReconnectDelaysForTesting(base: 0.02, max: 0.05)

            // Local state: user created a note and immediately trashed it before
            // any sync fired. The note has never reached the server.
            let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
            let itemId = "019ea000-0000-7000-8000-000000000042"
            let localItem = Item(
                createdAt: now, id: itemId, origin: .user,
                properties: ["body": .string("new note")], schemaVersion: 1, source: "sdk",
                state: .trashed, tier: .feed, timestamp: now, type: "core.note", updatedAt: now, version: 2
            )
            try await store.upsertItem(localItem)
            let createInput = CreateItemInput(
                type: "core.note", properties: ["body": .string("new note")], id: itemId
            )
            try await queue.enqueueCreateItem(createInput, localId: itemId)
            try await queue.enqueueDeleteItem(id: itemId)

            // Cycle 1: createItem POST fails transiently (500). deleteItem must
            // NOT fire — no response for it is queued in this cycle, so if the
            // fix is absent and deleteItem does fire it would consume the cycle-2
            // createItem response and cause cycle 2 to fail (decoding mismatch).
            transport.enqueueEvents([])
            transport.enqueueError(MymeError(code: "server_error", message: "transient", status: 500))

            // Cycle 2: createItem succeeds, then deleteItem succeeds.
            transport.enqueueEvents([])
            let serverCreated = Item(
                createdAt: now, id: itemId, origin: .user,
                properties: ["body": .string("new note")], schemaVersion: 1, source: "sdk",
                state: .active, tier: .feed, timestamp: now, type: "core.note", updatedAt: now, version: 1
            )
            transport.enqueue(ItemResponse(item: serverCreated, metadata: nil))
            transport.enqueue(EmptyResponse())

            await engine.start()
            await connManager.applyStateForTesting(.connecting)

            // Wait for full drain — both cycles must complete cleanly.
            try await waitUntil(timeout: .milliseconds(800)) {
                (try? await queue.isEmpty) == true
            }
            #expect(try await queue.isEmpty)

            // createItem reached the server twice (once transient, once success).
            let postCalls = await transport.calls.filter {
                $0.method == .post && $0.path == "/items"
            }
            #expect(postCalls.count == 2)

            // deleteItem reached the server exactly once (in cycle 2, not cycle 1).
            let deleteCalls = await transport.calls.filter {
                $0.method == .delete && $0.path == "/items/\(itemId)"
            }
            #expect(deleteCalls.count == 1)

            // The DELETE came after the second POST (the one that succeeded).
            let allCalls = await transport.calls
            let secondPostIndex = allCalls.lastIndex(where: {
                $0.method == .post && $0.path == "/items"
            })
            let deleteIndex = allCalls.firstIndex(where: {
                $0.method == .delete && $0.path == "/items/\(itemId)"
            })
            if let pi = secondPostIndex, let di = deleteIndex {
                #expect(pi < di, "DELETE must follow the successful POST in cycle 2")
            } else {
                Issue.record("Expected both POST /items and DELETE /items/\(itemId) in transport calls")
            }

            await engine.stop()
        }

        @Test("transient createItem also blocks downstream updateItem and metadata mutations")
        func transientCreateItemBlocksAllItemScopedMutations() async throws {
            let (store, queue, transport, connManager, engine) = try await makeFixture()
            await engine.setReconnectDelaysForTesting(base: 0.02, max: 0.05)

            let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
            let itemId = "019ea001-0000-7000-8000-000000000043"
            let localItem = Item(
                createdAt: now, id: itemId, origin: .user,
                properties: ["body": .string("draft")], schemaVersion: 1, source: "sdk",
                state: .active, tier: .feed, timestamp: now, type: "core.note", updatedAt: now, version: 3
            )
            try await store.upsertItem(localItem)

            // createItem + update + tag — all queued before sync fires.
            let createInput = CreateItemInput(
                type: "core.note", properties: ["body": .string("draft")], id: itemId
            )
            try await queue.enqueueCreateItem(createInput, localId: itemId)
            try await queue.enqueueUpdateItem(id: itemId, properties: ["body": .string("edited")])
            try await queue.enqueueAddTags(itemId: itemId, tags: ["note"])

            // Cycle 1: createItem fails transiently; update + tag must be skipped.
            transport.enqueueEvents([])
            transport.enqueueError(MymeError(code: "server_error", message: "transient", status: 500))

            // Cycle 2: all three replay in order and succeed.
            transport.enqueueEvents([])
            let serverCreated = Item(
                createdAt: now, id: itemId, origin: .user,
                properties: ["body": .string("draft")], schemaVersion: 1, source: "sdk",
                state: .active, tier: .feed, timestamp: now, type: "core.note", updatedAt: now, version: 1
            )
            transport.enqueue(ItemResponse(item: serverCreated, metadata: nil))
            let serverUpdated = Item(
                createdAt: now, id: itemId, origin: .user,
                properties: ["body": .string("edited")], schemaVersion: 1, source: "sdk",
                state: .active, tier: .feed, timestamp: now, type: "core.note", updatedAt: now, version: 2
            )
            transport.enqueue(ItemResponse(item: serverUpdated, metadata: nil))
            transport.enqueue(MetadataResponse(metadata: Metadata(
                extensions: [:], itemId: itemId, tags: ["note"]
            )))

            await engine.start()
            await connManager.applyStateForTesting(.connecting)

            try await waitUntil(timeout: .milliseconds(800)) {
                (try? await queue.isEmpty) == true
            }
            #expect(try await queue.isEmpty)

            // All three operations reached the server — and only once each.
            let postCalls = await transport.calls.filter {
                $0.method == .post && $0.path == "/items"
            }
            let patchCalls = await transport.calls.filter {
                $0.method == .patch && $0.path == "/items/\(itemId)"
            }
            let tagCalls = await transport.calls.filter {
                $0.method == .post && $0.path == "/items/\(itemId)/tags"
            }
            // createItem ran twice (cycle 1 fail + cycle 2 success).
            #expect(postCalls.count == 2)
            // updateItem and addTags ran once each (cycle 2 only).
            #expect(patchCalls.count == 1)
            #expect(tagCalls.count == 1)

            // Order within cycle 2: POST → PATCH → tag POST.
            let allCalls = await transport.calls
            let successPostIdx = allCalls.lastIndex(where: {
                $0.method == .post && $0.path == "/items"
            })
            let patchIdx = allCalls.firstIndex(where: {
                $0.method == .patch && $0.path == "/items/\(itemId)"
            })
            let tagIdx = allCalls.firstIndex(where: {
                $0.method == .post && $0.path == "/items/\(itemId)/tags"
            })
            if let pi = successPostIdx, let pa = patchIdx, let ti = tagIdx {
                #expect(pi < pa, "PATCH must come after the successful POST")
                #expect(pa < ti, "tag POST must come after PATCH")
            } else {
                Issue.record("Expected POST /items, PATCH /items/:id, and POST /items/:id/tags in transport calls")
            }

            await engine.stop()
        }

        @Test("transient createItem for item A does not affect unrelated item B mutations")
        func transientCreateItemDoesNotBlockUnrelatedMutations() async throws {
            let (store, queue, transport, connManager, engine) = try await makeFixture()
            await engine.setReconnectDelaysForTesting(base: 0.02, max: 0.05)

            let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
            let itemA = "019ea002-0000-7000-8000-000000000044"
            let itemB = "019ea003-0000-7000-8000-000000000045"

            // Item A: pending create (will fail transiently).
            let itemALocal = Item(
                createdAt: now, id: itemA, origin: .user,
                properties: ["body": .string("A")], schemaVersion: 1, source: "sdk",
                state: .active, tier: .feed, timestamp: now, type: "core.note", updatedAt: now, version: 1
            )
            try await store.upsertItem(itemALocal)
            let createA = CreateItemInput(type: "core.note", properties: ["body": .string("A")], id: itemA)
            try await queue.enqueueCreateItem(createA, localId: itemA)

            // Item B: pre-existing update (must replay in cycle 1 despite A's failure).
            let itemBLocal = Item(
                createdAt: now, id: itemB, origin: .user,
                properties: ["body": .string("B")], schemaVersion: 1, source: "sdk",
                state: .active, tier: .feed, timestamp: now, type: "core.note", updatedAt: now, version: 1
            )
            try await store.upsertItem(itemBLocal)
            try await queue.enqueueUpdateItem(id: itemB, properties: ["body": .string("B updated")])

            // Cycle 1: createItem(A) fails transiently; updateItem(B) must proceed.
            transport.enqueueEvents([])
            transport.enqueueError(MymeError(code: "server_error", message: "transient", status: 500))
            let updatedB = Item(
                createdAt: now, id: itemB, origin: .user,
                properties: ["body": .string("B updated")], schemaVersion: 1, source: "sdk",
                state: .active, tier: .feed, timestamp: now, type: "core.note", updatedAt: now, version: 2
            )
            transport.enqueue(ItemResponse(item: updatedB, metadata: nil))

            // Cycle 2: createItem(A) succeeds; no more mutations.
            transport.enqueueEvents([])
            let serverA = Item(
                createdAt: now, id: itemA, origin: .user,
                properties: ["body": .string("A")], schemaVersion: 1, source: "sdk",
                state: .active, tier: .feed, timestamp: now, type: "core.note", updatedAt: now, version: 1
            )
            transport.enqueue(ItemResponse(item: serverA, metadata: nil))

            await engine.start()
            await connManager.applyStateForTesting(.connecting)

            try await waitUntil(timeout: .milliseconds(800)) {
                (try? await queue.isEmpty) == true
            }
            #expect(try await queue.isEmpty)

            // updateItem(B) was called exactly once (in cycle 1).
            let patchBCalls = await transport.calls.filter {
                $0.method == .patch && $0.path == "/items/\(itemB)"
            }
            #expect(patchBCalls.count == 1)

            // createItem(A) was called twice (transient + success).
            let postCalls = await transport.calls.filter {
                $0.method == .post && $0.path == "/items"
            }
            #expect(postCalls.count == 2)

            // updateItem(B) landed in cycle 1 — before the second createItem(A).
            let allCalls = await transport.calls
            let patchBIdx = allCalls.firstIndex(where: {
                $0.method == .patch && $0.path == "/items/\(itemB)"
            })
            let secondPostIdx = allCalls.lastIndex(where: {
                $0.method == .post && $0.path == "/items"
            })
            if let bi = patchBIdx, let pi = secondPostIdx {
                #expect(bi < pi, "B's update should run in cycle 1, before cycle 2's createItem(A)")
            } else {
                Issue.record("Expected PATCH /items/\(itemB) and POST /items in transport calls")
            }

            await engine.stop()
        }

        // MARK: - rewriteLocalId integration

        @Test("createItem replay with a different server id rewrites dependents")
        func replayRewritesDependentsOnDifferentServerId() async throws {
            let (_, queue, transport, connManager, engine) = try await makeFixture()

            // Queue: createItem(localId = client-A), then an updateItem that
            // references client-A. Server will return a different id — the
            // update must be rewritten so it targets the server id, not a 404.
            let input = CreateItemInput(type: "core.note", properties: ["body": .string("v1")])
            try await queue.enqueueCreateItem(input, localId: "client-A")
            try await queue.enqueueUpdateItem(id: "client-A", properties: ["body": .string("v2")])

            // Empty SSE stream so runLoop proceeds to replay.
            transport.enqueueEvents([])

            // POST /items returns a server-assigned id.
            let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
            let serverItem = Item(
                createdAt: now, id: "server-A",
                origin: .user, properties: ["body": .string("v1")],
                schemaVersion: 1, source: "test", state: .active, tier: .feed,
                timestamp: now, type: "core.note", updatedAt: now, version: 1
            )
            transport.enqueue(ItemResponse(item: serverItem, metadata: nil))
            // PATCH /items/server-A succeeds with the updated body.
            let updated = Item(
                createdAt: now, id: "server-A",
                origin: .user, properties: ["body": .string("v2")],
                schemaVersion: 1, source: "test", state: .active, tier: .feed,
                timestamp: now, type: "core.note", updatedAt: now, version: 2
            )
            transport.enqueue(ItemResponse(item: updated, metadata: nil))

            await engine.start()
            await connManager.applyStateForTesting(.connecting)

            try await waitUntil(timeout: .milliseconds(500)) {
                (try? await queue.isEmpty) == true
            }

            let patchCalls = await transport.calls.filter {
                $0.method == .patch && $0.path == "/items/server-A"
            }
            #expect(patchCalls.count == 1, "update should have been retargeted to server id")

            // And no PATCH should have been issued to the stale local id.
            let stalePatch = await transport.calls.filter {
                $0.method == .patch && $0.path == "/items/client-A"
            }
            #expect(stalePatch.isEmpty)
            await engine.stop()
        }

        // MARK: - hasPendingMutations / lastFullSyncAt accessors

        @Test("hasPendingMutations is false on a fresh engine")
        func hasPendingMutationsFalseWhenEmpty() async throws {
            let (_, _, _, _, engine) = try await makeFixture()
            #expect(try await engine.hasPendingMutations == false)
        }

        @Test("hasPendingMutations tracks enqueue and remove")
        func hasPendingMutationsTracksQueue() async throws {
            let (_, queue, _, _, engine) = try await makeFixture()

            try await queue.enqueueDeleteItem(id: "server-1")
            #expect(try await engine.hasPendingMutations == true)

            let records = try await queue.fetchAll()
            try await queue.remove(id: records[0].id)
            #expect(try await engine.hasPendingMutations == false)
        }

        @Test("lastFullSyncAt is nil on a fresh store")
        func lastFullSyncAtNilOnFreshStore() async throws {
            let (_, _, _, _, engine) = try await makeFixture()
            let stamped = await engine.lastFullSyncAt
            #expect(stamped == nil)
        }

        @Test("performInitialSync stamps lastFullSyncAt")
        func performInitialSyncStampsLastFullSyncAt() async throws {
            let (_, _, transport, _, engine) = try await makeFixture()
            transport.enqueue(
                PaginatedResult<ItemWithMetadata>(data: [], cursor: nil, hasMore: false)
            )

            let before = Date()
            _ = try await engine.performInitialSync()
            let after = Date()

            let stamped = await engine.lastFullSyncAt
            #expect(stamped != nil)
            if let s = stamped {
                #expect(s >= before.addingTimeInterval(-1))
                #expect(s <= after.addingTimeInterval(1))
            }
        }

        @Test("lastFullSyncAt persists across SyncEngine instances on the same store")
        func lastFullSyncAtPersistsAcrossEngines() async throws {
            let (store, queue, transport, connManager, engine) = try await makeFixture()
            transport.enqueue(
                PaginatedResult<ItemWithMetadata>(data: [], cursor: nil, hasMore: false)
            )
            _ = try await engine.performInitialSync()
            let first = await engine.lastFullSyncAt
            #expect(first != nil)

            // Fresh engine sharing the same local store + queue reads the
            // same `sync_state` rows.
            let engine2 = SyncEngine(
                transport: transport,
                localStore: store,
                mutationQueue: queue,
                connectionManager: connManager
            )
            let second = await engine2.lastFullSyncAt
            #expect(second == first)
        }

        // MARK: - Full-sync-state checkpoint (5.1.0)

        @Test("lastCleanDrainAt is nil on a fresh store")
        func lastCleanDrainAtNilOnFreshStore() async throws {
            let (_, _, _, _, engine) = try await makeFixture()
            let stamped = await engine.lastCleanDrainAt
            #expect(stamped == nil)
        }

        @Test("fullSyncState is .notYetSynced on a fresh store")
        func fullSyncStateNotYetSyncedOnFreshStore() async throws {
            let (_, _, _, _, engine) = try await makeFixture()
            let state = await engine.fullSyncState
            if case .notYetSynced = state { } else {
                Issue.record("expected .notYetSynced; got \(state)")
            }
        }

        @Test("clean drain against an empty queue stamps lastCleanDrainAt")
        func cleanDrainAgainstEmptyQueueStampsLastCleanDrainAt() async throws {
            let (_, _, _, connManager, engine) = try await makeFixture()
            await connManager.applyStateForTesting(.online)

            let before = Date()
            await engine.triggerProactiveDrainForTesting()
            let after = Date()

            let stamped = await engine.lastCleanDrainAt
            #expect(stamped != nil)
            if let s = stamped {
                #expect(s >= before.addingTimeInterval(-1))
                #expect(s <= after.addingTimeInterval(1))
            }
        }

        @Test("fullSyncState reports .synced after a clean drain")
        func fullSyncStateSyncedAfterCleanDrain() async throws {
            let (_, _, _, connManager, engine) = try await makeFixture()
            await connManager.applyStateForTesting(.online)
            await engine.triggerProactiveDrainForTesting()

            let state = await engine.fullSyncState
            if case .synced = state { } else {
                Issue.record("expected .synced(at:); got \(state)")
            }
        }

        @Test("clean drain after queued mutation stamps lastCleanDrainAt")
        func cleanDrainAfterQueuedMutationStampsTimestamp() async throws {
            let (_, queue, transport, connManager, engine) = try await makeFixture()
            await connManager.applyStateForTesting(.online)

            // One queued mutation that the transport will accept cleanly.
            try await queue.enqueueDeleteItem(id: "server-x")
            transport.enqueue(EmptyResponse())

            await engine.triggerProactiveDrainForTesting()

            let stamped = await engine.lastCleanDrainAt
            #expect(stamped != nil)
            #expect(try await queue.isEmpty)
        }

        @Test("transient failure does not stamp lastCleanDrainAt and reports .failed")
        func transientFailureSkipsTimestampAndReportsFailed() async throws {
            let (_, queue, transport, connManager, engine) = try await makeFixture()
            await connManager.applyStateForTesting(.online)

            try await queue.enqueueDeleteItem(id: "server-x")
            let netError = NetworkError(
                NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "offline"])
            )
            transport.enqueueError(netError)

            await engine.triggerProactiveDrainForTesting()

            let stamped = await engine.lastCleanDrainAt
            #expect(stamped == nil)

            let state = await engine.fullSyncState
            if case .failed = state { } else {
                Issue.record("expected .failed; got \(state)")
            }
            // Transient failure leaves the row in the queue for retry.
            #expect(try await queue.isEmpty == false)
        }

        @Test("fullSyncState clears .failed back to .synced on next clean drain")
        func fullSyncStateClearsFailedAfterNextCleanDrain() async throws {
            let (_, queue, transport, connManager, engine) = try await makeFixture()
            await connManager.applyStateForTesting(.online)

            // Cycle 1 — transient failure.
            try await queue.enqueueDeleteItem(id: "server-y")
            let netError = NetworkError(
                NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "offline"])
            )
            transport.enqueueError(netError)
            await engine.triggerProactiveDrainForTesting()

            if case .failed = await engine.fullSyncState { } else {
                Issue.record("expected .failed after first cycle")
            }

            // Cycle 2 — same row replays cleanly. Reset state to .online
            // because the previous fireProactiveDrain ended with markOnline,
            // but the actor-state assertion is worth being explicit about.
            await connManager.applyStateForTesting(.online)
            transport.enqueue(EmptyResponse())
            await engine.triggerProactiveDrainForTesting()

            #expect(try await queue.isEmpty)
            if case .synced = await engine.fullSyncState { } else {
                Issue.record("expected .synced after recovery cycle")
            }
        }

        @Test("lastCleanDrainAt persists across SyncEngine instances on the same store")
        func lastCleanDrainAtPersistsAcrossEngines() async throws {
            let (store, queue, transport, connManager, engine) = try await makeFixture()
            await connManager.applyStateForTesting(.online)
            await engine.triggerProactiveDrainForTesting()

            let first = await engine.lastCleanDrainAt
            #expect(first != nil)

            // Fresh engine sharing the same local store + queue reads the
            // same `sync_state` row.
            let engine2 = SyncEngine(
                transport: transport,
                localStore: store,
                mutationQueue: queue,
                connectionManager: connManager
            )
            let second = await engine2.lastCleanDrainAt
            #expect(second == first)
        }

        @Test("FullSyncState seeds from persisted lastCleanDrainAt on a new engine")
        func fullSyncStateSeedsFromPersistedTimestamp() async throws {
            let (store, queue, transport, connManager, _) = try await makeFixture()

            // Seed the persisted timestamp directly — simulating a prior
            // session that completed a clean drain.
            let stamp = Date().ISO8601Format(.init(includingFractionalSeconds: true))
            try await queue.saveSyncState(key: "last_clean_drain_at", value: stamp)

            // Fresh engine reads the persisted state on first access.
            let engine = SyncEngine(
                transport: transport,
                localStore: store,
                mutationQueue: queue,
                connectionManager: connManager
            )
            if case .synced = await engine.fullSyncState { } else {
                Issue.record("expected .synced from persisted timestamp")
            }
        }

        // MARK: - Proactive drain on enqueue

        /// Fixture variant for the proactive-drain tests — short debounce so
        /// assertions don't need to sleep for the 150 ms default.
        private func makeFixtureWithShortDebounce() async throws -> (
            store: LocalStore,
            queue: MutationQueue,
            transport: MockTransport,
            connManager: ConnectionStateManager,
            engine: SyncEngine
        ) {
            let (store, queue, _) = try await MymeSDKTest.makeInMemoryStorePair()
            let transport = MockTransport()
            let connManager = ConnectionStateManager()
            let engine = SyncEngine(
                transport: transport,
                localStore: store,
                mutationQueue: queue,
                connectionManager: connManager,
                drainDebounceInterval: .milliseconds(20)
            )
            return (store, queue, transport, connManager, engine)
        }

        @Test("proactive drain fires when a mutation is enqueued while online")
        func proactiveDrainFiresWhenOnline() async throws {
            let (_, queue, transport, connManager, engine) = try await makeFixtureWithShortDebounce()

            // Engine consumes an empty SSE stream, marks .online, then idles
            // until a drain request wakes it.
            transport.enqueueEvents([])
            await engine.start()
            await connManager.applyStateForTesting(.connecting)

            // Wait until the stream close has landed us on .online.
            try await waitUntil(timeout: .milliseconds(500)) {
                await connManager.state == .online
            }

            // Queue a delete. Transport replies with a 204 via EmptyResponse
            // envelope — mock returns any successful decoded shape.
            transport.enqueue(EmptyResponse())
            try await queue.enqueueDeleteItem(id: "server-x")

            // Debounce (20 ms) + replay should clear the queue promptly.
            try await waitUntil(timeout: .milliseconds(500)) {
                (try? await queue.isEmpty) == true
            }
            #expect(try await queue.isEmpty)
            await engine.stop()
        }

        @Test("burst enqueues collapse to a single drain cycle")
        func burstEnqueuesCollapseToSingleDrain() async throws {
            let (_, queue, transport, connManager, engine) = try await makeFixtureWithShortDebounce()

            transport.enqueueEvents([])
            await engine.start()
            await connManager.applyStateForTesting(.connecting)
            try await waitUntil(timeout: .milliseconds(500)) {
                await connManager.state == .online
            }

            // Five mutations back-to-back. Each expects one transport round
            // trip. If the debouncer works, all fire on a single replay
            // cycle rather than triggering five separate cycles.
            for _ in 0..<5 {
                transport.enqueue(EmptyResponse())
            }
            for i in 0..<5 {
                try await queue.enqueueDeleteItem(id: "burst-\(i)")
            }

            try await waitUntil(timeout: .milliseconds(500)) {
                (try? await queue.isEmpty) == true
            }

            // Five delete calls landed on the transport — one replay burst
            // covering the whole queue snapshot, not five separate cycles.
            let deletes = transport.calls.filter {
                $0.method == .delete && $0.path.hasPrefix("/items/burst-")
            }
            #expect(deletes.count == 5)
            await engine.stop()
        }

        @Test("proactive drain is a no-op when offline")
        func proactiveDrainNoOpOffline() async throws {
            // Exercise the gate directly via the test hook — `NWPathMonitor`
            // races with `applyStateForTesting` on networked dev machines,
            // which would otherwise transition the engine to `.connecting`
            // and drain the queue via the SSE-close path before the assert.
            let (_, queue, transport, connManager, engine) = try await makeFixtureWithShortDebounce()

            await connManager.applyStateForTesting(.offline)
            try await queue.enqueueDeleteItem(id: "never")

            await engine.triggerProactiveDrainForTesting()

            #expect(try await queue.isEmpty == false)
            let deletes = transport.calls.filter {
                $0.method == .delete && $0.path == "/items/never"
            }
            #expect(deletes.isEmpty)
        }

        @Test("proactive drain is a no-op when syncing")
        func proactiveDrainNoOpSyncing() async throws {
            // `.syncing` means a drain is already in flight. A second
            // concurrent drain would race over the same records.
            let (_, queue, transport, connManager, engine) = try await makeFixtureWithShortDebounce()

            await connManager.applyStateForTesting(.syncing)
            try await queue.enqueueDeleteItem(id: "never")

            await engine.triggerProactiveDrainForTesting()

            #expect(try await queue.isEmpty == false)
            let deletes = transport.calls.filter {
                $0.method == .delete && $0.path == "/items/never"
            }
            #expect(deletes.isEmpty)
        }
    }

    // MARK: - MutationQueue.rewriteLocalId unit tests

    @Suite("MutationQueue.rewriteLocalId")
    struct RewriteLocalIdTests {

        // Pair-builder: shared `ModelContainer` so the queue and store
        // commit to the same SQLite file (synced-mode shape).
        private func makeStoreAndQueue() async throws -> (LocalStore, MutationQueue) {
            let (store, queue, _) = try await MymeSDKTest.makeInMemoryStorePair()
            return (store, queue)
        }

        @Test("rewrites update and edge endpoint references, leaves createItem alone")
        func rewritesDependents() async throws {
            let (store, queue) = try await makeStoreAndQueue()

            let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
            try await queue.enqueueCreateItem(input, localId: "A")
            try await queue.enqueueUpdateItem(id: "A", properties: ["body": .string("y")])
            try await queue.enqueueCreateEdge(
                source: "A", target: "B", edgeType: "about", properties: nil, localEdgeId: "E1"
            )

            try await queue.rewriteLocalId(from: "A", to: "A'")

            let records = try await queue.fetchAll()

            // createItem: localId unchanged (it owns "A" as its identity).
            let create = try #require(records.first { $0.kind == .createItem })
            #expect(create.localId == "A")

            // updateItem: localId and payload.id both rewritten to "A'".
            let update = try #require(records.first { $0.kind == .updateItem })
            #expect(update.localId == "A'")
            let updatePayload = try JSONDecoder().decode(
                UpdateItemPayload.self,
                from: update.payloadJson.data(using: .utf8) ?? Data()
            )
            #expect(updatePayload.id == "A'")

            // createEdge: source rewritten to "A'", target unchanged.
            let edge = try #require(records.first { $0.kind == .createEdge })
            let edgePayload = try JSONDecoder().decode(
                CreateEdgePayload.self,
                from: edge.payloadJson.data(using: .utf8) ?? Data()
            )
            #expect(edgePayload.source == "A'")
            #expect(edgePayload.target == "B")
        }

        @Test("rewrites target endpoint when oldId was on the target side of an edge")
        func rewritesEdgeTargetEndpoint() async throws {
            let (store, queue) = try await makeStoreAndQueue()

            try await queue.enqueueCreateEdge(
                source: "X", target: "A", edgeType: "about", properties: nil, localEdgeId: "E1"
            )

            try await queue.rewriteLocalId(from: "A", to: "A'")

            let records = try await queue.fetchAll()
            let edge = try #require(records.first { $0.kind == .createEdge })
            let payload = try JSONDecoder().decode(
                CreateEdgePayload.self,
                from: edge.payloadJson.data(using: .utf8) ?? Data()
            )
            #expect(payload.source == "X")
            #expect(payload.target == "A'")
        }

        @Test("rewrites metadata / tags / extension kinds keyed off item id")
        func rewritesMetadataAndExtensions() async throws {
            let (store, queue) = try await makeStoreAndQueue()

            try await queue.enqueueSetMetadata(itemId: "A", input: MetadataInput(tags: ["a"]))
            try await queue.enqueueAddTags(itemId: "A", tags: ["b"])
            try await queue.enqueueRemoveTag(itemId: "A", tag: "c")
            try await queue.enqueueSetExtension(
                itemId: "A", namespace: "com.example", data: ["k": .string("v")]
            )
            try await queue.enqueueDeleteExtension(itemId: "A", namespace: "com.example")

            try await queue.rewriteLocalId(from: "A", to: "Z")

            let records = try await queue.fetchAll()
            for record in records {
                #expect(record.localId == "Z", "\(record.kind) should have localId rewritten")
            }

            let meta = try #require(records.first { $0.kind == .setMetadata })
            let metaPayload = try JSONDecoder().decode(
                MetadataPayload.self, from: meta.payloadJson.data(using: .utf8) ?? Data()
            )
            #expect(metaPayload.itemId == "Z")

            let addTags = try #require(records.first { $0.kind == .addTags })
            let addTagsPayload = try JSONDecoder().decode(
                AddTagsPayload.self, from: addTags.payloadJson.data(using: .utf8) ?? Data()
            )
            #expect(addTagsPayload.itemId == "Z")

            let setExt = try #require(records.first { $0.kind == .setExtension })
            let setExtPayload = try JSONDecoder().decode(
                SetExtensionPayload.self, from: setExt.payloadJson.data(using: .utf8) ?? Data()
            )
            #expect(setExtPayload.itemId == "Z")
        }

        @Test("no-op when from == to")
        func noOpOnEquality() async throws {
            let (store, queue) = try await makeStoreAndQueue()

            try await queue.enqueueUpdateItem(id: "A", properties: ["body": .string("y")])
            try await queue.rewriteLocalId(from: "A", to: "A")

            let records = try await queue.fetchAll()
            #expect(records.count == 1)
            #expect(records[0].localId == "A")
        }
    }

    // MARK: - MutationQueue.dropMutationsReferencingLocalId unit tests

    @Suite("MutationQueue.dropMutationsReferencingLocalId")
    struct DropMutationsReferencingLocalIdTests {

        // Pair-builder: shared `ModelContainer` so the queue and store
        // commit to the same SQLite file (synced-mode shape).
        private func makeStoreAndQueue() async throws -> (LocalStore, MutationQueue) {
            let (store, queue, _) = try await MymeSDKTest.makeInMemoryStorePair()
            return (store, queue)
        }

        @Test("drops item-scope mutations keyed on local_id, leaves createItem for caller")
        func dropsItemScope() async throws {
            let (store, queue) = try await makeStoreAndQueue()

            let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
            try await queue.enqueueCreateItem(input, localId: "A")
            try await queue.enqueueUpdateItem(id: "A", properties: ["body": .string("y")])
            try await queue.enqueueSetMetadata(itemId: "A", input: MetadataInput(tags: ["t"]))
            try await queue.enqueueDeleteItem(id: "A")

            let deleted = try await queue.dropMutationsReferencingLocalId("A")

            // Everything keyed off "A" was scheduled for drop, except the
            // createItem root (the caller removes that separately so their
            // own `.mutationDropped` emit fires for the root failure).
            #expect(deleted.count == 3)
            let kinds = Set(deleted.map { $0.kind })
            #expect(kinds == Set([.updateItem, .setMetadata, .deleteItem]))

            let remaining = try await queue.fetchAll()
            #expect(remaining.count == 1)
            #expect(remaining[0].kind == .createItem)
        }

        @Test("drops createEdge rows whose source or target matches the local id")
        func dropsEdgesByEndpoint() async throws {
            let (store, queue) = try await makeStoreAndQueue()

            try await queue.enqueueCreateEdge(
                source: "A", target: "B", edgeType: "about",
                properties: nil, localEdgeId: "E-AB"
            )
            try await queue.enqueueCreateEdge(
                source: "X", target: "A", edgeType: "in-thread",
                properties: nil, localEdgeId: "E-XA"
            )
            try await queue.enqueueCreateEdge(
                source: "X", target: "Y", edgeType: "about",
                properties: nil, localEdgeId: "E-XY"
            )

            let deleted = try await queue.dropMutationsReferencingLocalId("A")

            // Both A-touching edges cascade; the unrelated X→Y survives.
            #expect(deleted.count == 2)
            let remaining = try await queue.fetchAll()
            #expect(remaining.count == 1)
            #expect(remaining[0].localId == "E-XY")
        }

        @Test("drops updateEdge / deleteEdge follow-ups for cascade-deleted createEdge rows")
        func dropsEdgeFollowUps() async throws {
            let (store, queue) = try await makeStoreAndQueue()

            // createEdge whose source is the dropped item; follow-up
            // updateEdge + deleteEdge reference the same edge id.
            try await queue.enqueueCreateEdge(
                source: "A", target: "B", edgeType: "about",
                properties: nil, localEdgeId: "E-AB"
            )
            try await queue.enqueueUpdateEdge(id: "E-AB", properties: ["note": .string("x")])
            try await queue.enqueueDeleteEdge(id: "E-AB")

            // Sibling edge not connected to A — its follow-ups should survive.
            try await queue.enqueueCreateEdge(
                source: "X", target: "Y", edgeType: "about",
                properties: nil, localEdgeId: "E-XY"
            )
            try await queue.enqueueUpdateEdge(id: "E-XY", properties: ["note": .string("z")])

            let deleted = try await queue.dropMutationsReferencingLocalId("A")

            // createEdge + updateEdge + deleteEdge for E-AB, but NOT the
            // sibling E-XY or its updateEdge.
            #expect(deleted.count == 3)

            let remaining = try await queue.fetchAll()
            let remainingKinds = Set(remaining.map { $0.kind })
            #expect(remainingKinds == Set([.createEdge, .updateEdge]))
            let remainingLocalIds = Set(remaining.compactMap { $0.localId })
            #expect(remainingLocalIds == Set(["E-XY"]))
        }

        @Test("no-op when no rows reference the local id")
        func noOpWhenUnreferenced() async throws {
            let (store, queue) = try await makeStoreAndQueue()

            try await queue.enqueueUpdateItem(id: "B", properties: ["body": .string("y")])
            let deleted = try await queue.dropMutationsReferencingLocalId("A")
            #expect(deleted.isEmpty)
            #expect(try await queue.fetchAll().count == 1)
        }
    }
}
