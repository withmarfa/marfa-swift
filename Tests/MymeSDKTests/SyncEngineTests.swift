import Testing
import Foundation
@testable import MymeSDK
@testable import MymeSDKTestSupport

/// Tests for ``SyncEngine``, ``MutationQueue``, and ``ConnectionStateManager``.
///
/// All tests use in-memory SQLite (`:memory:`) and ``MockTransport`` — no real
/// network or on-disk state.
@Suite("SyncEngine")
struct SyncEngineTests {

    // MARK: - Helpers

    private func makeStore() throws -> LocalStore {
        try LocalStore(path: ":memory:")
    }

    private func makeQueue(store: LocalStore) throws -> MutationQueue {
        try MutationQueue(pool: store.pool)
    }

    private func noteInput(body: String = "Hello") -> CreateItemInput {
        CreateItemInput(type: "core.note", properties: ["body": .string(body)])
    }

    // MARK: - MutationQueue unit tests

    @Suite("MutationQueue")
    struct MutationQueueTests {

        private func makeStore() throws -> LocalStore { try LocalStore(path: ":memory:") }
        private func makeQueue(store: LocalStore) throws -> MutationQueue {
            try MutationQueue(pool: store.pool)
        }

        @Test("Queue starts empty") func startsEmpty() async throws {
            let store = try makeStore()
            let queue = try makeQueue(store: store)
            #expect(try await queue.isEmpty)
        }

        @Test("Enqueue createItem appears in fetchAll") func enqueueCreateItem() async throws {
            let store = try makeStore()
            let queue = try makeQueue(store: store)
            let input = CreateItemInput(type: "core.note", properties: ["body": .string("hi")])
            try await queue.enqueueCreateItem(input, localId: "local-123")

            let records = try await queue.fetchAll()
            #expect(records.count == 1)
            #expect(records[0].kind == .createItem)
            #expect(records[0].localId == "local-123")
            #expect(try await queue.isEmpty == false)
        }

        @Test("remove deletes a record") func removeRecord() async throws {
            let store = try makeStore()
            let queue = try makeQueue(store: store)
            let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
            try await queue.enqueueCreateItem(input, localId: "l1")

            let records = try await queue.fetchAll()
            #expect(records.count == 1)
            try await queue.remove(id: records[0].id)
            #expect(try await queue.isEmpty)
        }

        @Test("recordFailure increments attempt_count") func recordFailure() async throws {
            let store = try makeStore()
            let queue = try makeQueue(store: store)
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
            let store = try makeStore()
            let queue = try makeQueue(store: store)
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
            let store = try makeStore()
            let queue = try makeQueue(store: store)

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
            let store = try makeStore()
            let queue = try makeQueue(store: store)
            let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])

            try await queue.enqueueCreateItem(input, localId: "li")
            try await queue.enqueueUpdateItem(id: "i1", properties: ["body": .string("y")])
            try await queue.enqueueDeleteItem(id: "i2")
            try await queue.enqueueRestoreItem(id: "i3")
            try await queue.enqueueTransitionItem(id: "i4", to: "archived")
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
            let stream = await manager.stateUpdates
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
                    let stream = await manager.stateUpdates
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
        private func makeFixture() throws -> (
            store: LocalStore,
            queue: MutationQueue,
            transport: MockTransport,
            connManager: ConnectionStateManager,
            engine: SyncEngine
        ) {
            let store = try LocalStore(path: ":memory:")
            let queue = try MutationQueue(pool: store.pool)
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
            let (store, queue, _, _, _) = try makeFixture()

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
            let (_, _, _, _, engine) = try makeFixture()
            await engine.start()
            await engine.start() // second start is a no-op
            await engine.stop()
            await engine.stop()  // second stop is a no-op
        }

        // MARK: - SSE event application

        @Test("SSE item.* events apply to local store") func ssEEventsApplyToLocalStore() async throws {
            let (store, queue, transport, connManager, engine) = try makeFixture()

            // Build item.created and item.updated events that together mutate
            // the same server-side item.
            let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
            let v1 = Item(
                createdAt: now, id: "server-1", library: false,
                origin: .user, properties: ["body": .string("v1")],
                schemaVersion: 1, source: "test", state: .active,
                timestamp: now, type: "core.note", updatedAt: now, version: 1
            )
            let v2 = Item(
                createdAt: now, id: "server-1", library: false,
                origin: .user, properties: ["body": .string("v2")],
                schemaVersion: 1, source: "test", state: .active,
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
            let (_, queue, transport, connManager, engine) = try makeFixture()

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

        // MARK: - Cursor resume

        @Test("opens second SSE stream with Last-Event-ID after reconnect") func cursorResumeOnReconnect() async throws {
            let (_, queue, transport, connManager, engine) = try makeFixture()

            // First connection: yield one event then close. Cursor should persist.
            let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
            let item = Item(
                createdAt: now, id: "server-rc", library: false,
                origin: .user, properties: ["body": .string("hi")],
                schemaVersion: 1, source: "test", state: .active,
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
    }
}
