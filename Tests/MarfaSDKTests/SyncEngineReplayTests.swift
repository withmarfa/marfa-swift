import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// Mutation replay behavior:
/// - Error classification (transient vs permanent) and failure accounting.
/// - Cascade drop when a `createItem` fails permanently.
/// - Id stamping + replay reconciliation (no-op when server echoes the id;
///   dependent rewrites when server returns a different id).
/// - Transient `createItem` blocking downstream same-item mutations within
///   a single replay cycle (and *not* blocking unrelated items).
/// - SSE reconnect nudge draining mutations queued after the first cycle.
///
/// Shared helpers live in ``SyncEngineTestKit`` (see SyncEngineTestSupport.swift).
@Suite("SyncEngine replay", .timeLimit(.minutes(1)))
struct SyncEngineReplayTests {

    // MARK: - Error classification

    @Test("mutation replay records failure when transport throws") func mutationReplayRecordsFailure() async throws {
        let (_, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()

        // A single pending delete the engine will try to replay.
        try await queue.enqueueDeleteItem(id: "server-x")

        // The DELETE throws a network-class error.
        let netError = NetworkError(
            NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "offline"])
        )
        transport.enqueueError(netError)

        await connManager.applyStateForTesting(.online)
        // One cycle, driven directly — see the note on the mixed-cycle test
        // for why starting the engine makes a per-cycle count load-dependent.
        await engine.triggerProactiveDrainForTesting()

        let remaining = try await queue.fetchAll()
        #expect(remaining.count == 1)
        let replayCalls = transport.calls.filter {
            $0.method == .delete && $0.path == "/items/server-x"
        }
        #expect(replayCalls.count == 1)
        let record = try #require(remaining.first)
        #expect(record.attemptCount == 1)
        #expect(record.lastError?.contains("offline") == true)
    }

    @Test("stop waits for in-flight replay accounting to finish")
    func stopIsQuiescenceBarrier() async throws {
        let (store, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        let transport = BlockingReplayTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        try await queue.enqueueDeleteItem(id: "server-stop")

        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        await transport.waitUntilRequestStarted()

        let stopTask = Task { await engine.stop() }
        try await SyncEngineTestKit.awaitCondition(description: "engine.isStoppingForTesting") {
            await engine.isStoppingForTesting
        }
        #expect(await transport.requestCallCount == 1)

        await transport.releaseRequest()
        await stopTask.value

        let remaining = try await queue.fetchAll()
        #expect(remaining.count == 1)
        let record = try #require(remaining.first)
        #expect(record.attemptCount == 1)
        #expect(record.lastError?.contains("released failure") == true)
        #expect(await transport.requestCallCount == 1)
    }

    @Test("cancellation before replay never stamps a clean drain")
    func cancellationBeforeReplayDoesNotStampCleanDrain() async throws {
        let (_, queue, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await queue.enqueueDeleteItem(id: "server-cancelled")

        await engine.start()
        await engine.stop()
        await engine.replayMutationsForTesting()

        #expect(await engine.lastCleanDrainAt == nil)
        #expect(try await queue.isEmpty == false)
    }

    @Test("successful partial replay after stop does not stamp a clean drain")
    func partialReplayAfterStopDoesNotStampCleanDrain() async throws {
        let (store, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        let transport = BlockingSuccessfulReplayTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        try await queue.enqueueDeleteItem(id: "server-first")
        try await queue.enqueueDeleteItem(id: "server-second")

        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        await transport.waitUntilRequestStarted()

        let stopTask = Task { await engine.stop() }
        try await SyncEngineTestKit.awaitCondition(description: "engine.isStoppingForTesting") {
            await engine.isStoppingForTesting
        }
        await transport.releaseRequest()
        await stopTask.value

        #expect(await engine.lastCleanDrainAt == nil)
        let remaining = try await queue.fetchAll()
        #expect(remaining.count == 1)
        let record = try #require(remaining.first)
        #expect(record.localId == "server-second")
    }

    @Test("a mutation queued mid-cycle blocks the clean-drain stamp")
    func mutationQueuedDuringReplayBlocksCleanDrain() async throws {
        let (store, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        let transport = BlockingSuccessfulReplayTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        try await queue.enqueueDeleteItem(id: "server-first")
        await connManager.applyStateForTesting(.online)

        // Drive the drain directly rather than starting the engine: the
        // proactive-drain listener would pick the second record up on its own
        // debounce and stamp a legitimate clean drain, hiding the defect.
        let drain = Task { await engine.triggerProactiveDrainForTesting() }
        await transport.waitUntilRequestStarted()

        // Enqueued after the cycle read the queue, so the replay list this
        // cycle is working from is already stale. The cycle succeeds on
        // everything it knows about, which is not the same as a drained queue.
        try await queue.enqueueDeleteItem(id: "server-second")
        await transport.releaseRequest()
        await drain.value

        #expect(await engine.lastCleanDrainAt == nil)
        let remaining = try await queue.fetchAll()
        #expect(remaining.count == 1)
        let record = try #require(remaining.first)
        #expect(record.localId == "server-second")
    }

    @Test("mutation replay drops queued record on 404 NotFoundError") func mutationReplayDropsOn404() async throws {
        let (_, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()

        // Queue an update against an item the server "doesn't have". The id is
        // a UUIDv7, the shape the server accepts, so the 404 is about the row
        // being absent rather than the id being rejected.
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
        try await SyncEngineTestKit.awaitCondition(description: "(try? await queue.isEmpty) == true") {
            (try? await queue.isEmpty) == true
        }

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
        let (_, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()

        // A UUIDv4 rather than the UUIDv7 the server requires, so it answers
        // INVALID_ID (400) — a permanent failure no retry can clear.
        try await queue.enqueueUpdateItem(
            id: "6837a0e8-d316-4433-ac4c-d1e40f19615f",
            properties: ["body": .string("bad id")]
        )

        transport.enqueueEvents([])
        transport.enqueueError(ValidationError(message: "Invalid item ID"))

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.awaitCondition(description: "(try? await queue.isEmpty) == true") {
            (try? await queue.isEmpty) == true
        }
        await engine.stop()
    }

    @Test("mutation replay retains queued record on transient 5xx") func mutationReplayRetainsOn5xx() async throws {
        let (_, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()

        try await queue.enqueueUpdateItem(
            id: "019da086-d675-7cd8-ba3f-3dc4e6e7bd42",
            properties: ["body": .string("temp fail")]
        )

        // 500 is transient — MarfaError base class, not a permanent subclass.
        transport.enqueueError(MarfaError(
            code: "server_error", message: "boom", status: 500
        ))

        await connManager.applyStateForTesting(.online)
        // One cycle, driven directly — see the note on the mixed-cycle test
        // for why starting the engine makes a per-cycle count load-dependent.
        await engine.triggerProactiveDrainForTesting()

        let remaining = try await queue.fetchAll()
        #expect(remaining.count == 1)
        let replayCalls = transport.calls.filter {
            $0.method == .patch && $0.path == "/items/019da086-d675-7cd8-ba3f-3dc4e6e7bd42"
        }
        #expect(replayCalls.count == 1)
        let record = try #require(remaining.first)
        #expect(record.attemptCount == 1)
    }

    @Test("mixed queue drops permanent + retains transient in one cycle") func mutationReplayMixedCycle() async throws {
        let (_, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()

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

        transport.enqueueError(NotFoundError(message: "gone"))
        transport.enqueueError(NetworkError(
            NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "offline"])
        ))

        await connManager.applyStateForTesting(.online)
        // Drive exactly one cycle rather than starting the engine. Starting it
        // arms the real NWPathMonitor, whose first callback arrives after the
        // stream has closed and the manager has moved to `.online`, flipping it
        // back to `.connecting` and opening a second replay cycle. Whether that
        // lands before the stop is a matter of machine load, and it is what the
        // per-cycle counts below would otherwise be measuring.
        await engine.triggerProactiveDrainForTesting()

        let remaining = try await queue.fetchAll()
        #expect(remaining.count == 1)
        let record = try #require(remaining.first)
        #expect(record.localId == "019eb000-0000-7000-8000-000000000000")
        let replayCalls = transport.calls.filter {
            $0.method == .patch && $0.path == "/items/019eb000-0000-7000-8000-000000000000"
        }
        #expect(replayCalls.count == 1)
        #expect(record.attemptCount == 1)
    }

    // MARK: - Id stamping + replay reconciliation

    @Test("ItemsNamespace.create stamps a UUIDv7 into the queued payload when input.id is nil")
    func createStampsIdIntoEnqueuedPayload() async throws {
        let (store, queue, transport, _, _) = try await SyncEngineTestKit.makeFixture()
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
        let (store, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
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
            properties: ["body": .string("v1")],
            schemaVersion: 1, source: "test", state: .active, tier: .feed,
            timestamp: now, type: "core.note", updatedAt: now, version: 1
        )
        transport.enqueue(ItemResponse(item: echoed, metadata: nil))

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.awaitCondition(description: "(try? await queue.isEmpty) == true") {
            (try? await queue.isEmpty) == true
        }

        // Local row still present under the stamped id — no purge fired.
        let fetched = try await store.fetchItem(id: created.id)
        #expect(fetched.id == created.id)
        await engine.stop()
    }

    @Test("createItem replay with a different server id rewrites dependents")
    func replayRewritesDependentsOnDifferentServerId() async throws {
        let (_, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()

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
            properties: ["body": .string("v1")],
            schemaVersion: 1, source: "test", state: .active, tier: .feed,
            timestamp: now, type: "core.note", updatedAt: now, version: 1
        )
        transport.enqueue(ItemResponse(item: serverItem, metadata: nil))
        // PATCH /items/server-A succeeds with the updated body.
        let updated = Item(
            createdAt: now, id: "server-A",
            properties: ["body": .string("v2")],
            schemaVersion: 1, source: "test", state: .active, tier: .feed,
            timestamp: now, type: "core.note", updatedAt: now, version: 2
        )
        transport.enqueue(ItemResponse(item: updated, metadata: nil))

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.awaitCondition(description: "(try? await queue.isEmpty) == true") {
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

    // MARK: - Edge create replay

    /// The tests below are one contract seen from several sides: an edge the
    /// device wrote keeps its id all the way to the server, so the row the
    /// device holds is the row the server holds.
    ///
    /// They build the edge through ``EdgesNamespace`` rather than by enqueuing
    /// a record directly, because the id under test is the one the local store
    /// writes the row under. A hand-written queue record would assert against
    /// an id the test chose, which is the one value that cannot be wrong.
    ///
    /// The ones that need a server whose answer depends on the request run
    /// against ``EdgeMintingTransport``; see that type for why a canned answer
    /// cannot see this defect. The upsert tests deliberately use
    /// `MockTransport` instead, because it delivers no echo — an echo re-lands
    /// the same row under the same id, so a test that receives one stays green
    /// with the replay's own upsert deleted.
    private func syncedEdges(
        transport: any Transport, store: LocalStore, queue: MutationQueue
    ) -> EdgesNamespace {
        EdgesNamespace(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            maxBackrefBatchConcurrency: 8
        )
    }

    private func mintingFixture() async throws -> (
        LocalStore, MutationQueue, EdgeMintingTransport, ConnectionStateManager, SyncEngine
    ) {
        let (store, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        try await SyncEngineTestKit.markImported(queue)
        let transport = EdgeMintingTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        await engine.setReconnectDelaysForTesting(base: 0.01, max: 0.05)
        return (store, queue, transport, connManager, engine)
    }

    /// The server's copy of a row the device wrote: the same id, carrying a
    /// space and a timestamp the local mint cannot produce.
    private func serverCopy(of edge: Edge) -> Edge {
        Edge(
            createdAt: EdgeMintingTransport.stampedAt,
            edgeType: edge.edgeType,
            id: edge.id,
            properties: edge.properties,
            sourceId: edge.sourceId,
            spaceId: EdgeMintingTransport.spaceId,
            targetId: edge.targetId,
            updatedAt: EdgeMintingTransport.stampedAt,
            version: 1
        )
    }

    @Test("the replayed edge create carries the id the device minted")
    func edgeReplaySendsTheMintedId() async throws {
        let (store, queue, transport, connManager, engine) = try await mintingFixture()
        let edges = syncedEdges(transport: transport, store: store, queue: queue)

        let created = try await edges.create(
            source: "src", target: "tgt", edgeType: "about"
        )

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.awaitCondition(description: "(try? await queue.isEmpty) == true") {
            (try? await queue.isEmpty) == true
        }

        let post = try #require(
            await transport.calls.first { $0.method == .post && $0.path == "/edges" }
        )
        let sent = try JSONSerialization.jsonObject(
            with: try #require(post.body)
        ) as? [String: Any]
        #expect(sent?["id"] as? String == created.id)
        await engine.stop()
    }

    @Test("an edge created here is one row here once the server echoes it back")
    func edgeCreatedHereStaysOneRow() async throws {
        let (store, queue, transport, connManager, engine) = try await mintingFixture()
        let edges = syncedEdges(transport: transport, store: store, queue: queue)

        let created = try await edges.create(
            source: "src", target: "tgt", edgeType: "about"
        )

        // Subscribed before the cycle starts so the echo's event is caught.
        let events = engine.events
        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        // The echo is what puts a second row in the store, so wait for it to
        // land rather than racing it: a count taken before it arrives passes
        // for the wrong reason and stays green after a fix that changed
        // nothing. The cursor moving is the device having applied it.
        try await SyncEngineTestKit.awaitCondition(description: "(try? await queue.loadSyncState(key: \"last_event_id\")) == \"evt-1\""
        ) {
            (try? await queue.loadSyncState(key: "last_event_id")) == "evt-1"
        }

        let local = try await store.fetchEdgesFromSource(
            sourceId: "src", edgeType: "about", cursor: nil, limit: nil
        )
        #expect(
            local.data.count == 1,
            "local edge ids from that source: \(local.data.map(\.id))"
        )
        #expect(local.data.first?.id == created.id)

        // What the echo is announced as, and not only that a row landed. Both
        // edge events apply through the same upsert, so a case that handled
        // the two together and published one name would leave every stored-row
        // assertion in this repository green while telling an app that an edge
        // it has just seen created was edited instead.
        let published = await SyncEngineTestKit.publishedEvents(from: events, closing: engine)
        #expect(
            published.contains { if case .edgeCreated(created.id) = $0 { return true } else { return false } },
            "expected .edgeCreated(\(created.id)), got \(published)"
        )
        #expect(
            !published.contains { if case .edgeUpdated = $0 { return true } else { return false } },
            "a create echo announced as an edit: \(published)"
        )
    }

    @Test("a bulk edge create keeps the ids the device wrote its rows under")
    func bulkEdgeReplayKeepsLocalIds() async throws {
        let (store, queue, transport, connManager, engine) = try await mintingFixture()
        let edges = syncedEdges(transport: transport, store: store, queue: queue)

        // One edge the caller names itself and one it leaves to the store.
        // Both have local rows before anything reaches the network, and both
        // have to reach the server under those ids. `emitEvents` is on
        // because the echo is the half that duplicates the row, and the bulk
        // route publishes nothing unless the caller asks.
        let callerId = "01a06000-0000-7000-8000-00000000000a"
        let result = try await edges.bulk(
            BulkEdgeInput(
                edges: [
                    BulkEdgeInputItem(
                        id: callerId, sourceId: "src", targetId: "tgt-1", edgeType: "about"
                    ),
                    BulkEdgeInputItem(
                        sourceId: "src", targetId: "tgt-2", edgeType: "about"
                    ),
                ],
                emitEvents: true
            )
        )
        let named = try #require(result.results.first { $0.index == 0 })
        let unnamed = try #require(result.results.first { $0.index == 1 })
        // The caller's own id names the local row, rather than being dropped
        // in favor of a mint the caller never sees.
        #expect(named.id == callerId)
        let mintedId = try #require(unnamed.id)

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.awaitCondition(description: "(try? await queue.loadSyncState(key: \"last_event_id\")) == \"evt-2\""
        ) {
            (try? await queue.loadSyncState(key: "last_event_id")) == "evt-2"
        }

        let local = try await store.fetchEdgesFromSource(
            sourceId: "src", edgeType: "about", cursor: nil, limit: nil
        )
        #expect(
            local.data.count == 2,
            "local edge ids from that source: \(local.data.map(\.id))"
        )
        #expect(Set(local.data.map(\.id)) == Set([callerId, mintedId]))

        let post = try #require(
            await transport.calls.first { $0.method == .post && $0.path == "/edges/bulk" }
        )
        let body = try JSONSerialization.jsonObject(
            with: try #require(post.body)
        ) as? [String: Any]
        let sentIds = (body?["edges"] as? [[String: Any]])?.map { $0["id"] as? String }
        #expect(sentIds == [callerId, mintedId])
        await engine.stop()
    }

    @Test("a bulk item create keeps the ids the device wrote its rows under")
    func bulkItemReplayKeepsLocalIds() async throws {
        let (store, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        try await SyncEngineTestKit.markImported(queue)
        let transport = ItemMintingTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        await engine.setReconnectDelaysForTesting(base: 0.01, max: 0.05)
        let items = ItemsNamespace(
            transport: transport,
            defaultConflictStrategy: .auto,
            localStore: store,
            mutationQueue: queue
        )

        // One entry the caller names itself and one it leaves to the store.
        // Both have local rows before anything reaches the network, and both
        // have to reach the server under those ids. `emitEvents` is on because
        // the echo is the half that duplicates the row, and the bulk route
        // publishes nothing unless the caller asks.
        let callerId = "01b06000-0000-7000-8000-00000000000a"
        let result = try await items.bulk(
            BulkInput(
                items: [
                    BulkItemInput(id: callerId, type: "core.note"),
                    BulkItemInput(type: "core.note"),
                ],
                emitEvents: true
            )
        )
        let named = try #require(result.results.first { $0.index == 0 })
        let unnamed = try #require(result.results.first { $0.index == 1 })
        #expect(named.id == callerId)
        let mintedId = try #require(unnamed.id)

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.awaitCondition(description: "(try? await queue.loadSyncState(key: \"last_event_id\")) == \"evt-2\""
        ) {
            (try? await queue.loadSyncState(key: "last_event_id")) == "evt-2"
        }

        // Two rows in, two rows out. Before the fix the replay sent the
        // caller's input verbatim, so the entry the store had named was minted
        // again server-side and the echo inserted a third and fourth row
        // beside the two already there.
        let local = try await store.fetchItems(filters: ListFilters(type: "core.note"))
        #expect(
            local.data.count == 2,
            "local item ids: \(local.data.map(\.id))"
        )
        #expect(Set(local.data.map(\.id)) == Set([callerId, mintedId]))

        let post = try #require(
            await transport.calls.first { $0.method == .post && $0.path == "/items/bulk" }
        )
        let body = try JSONSerialization.jsonObject(
            with: try #require(post.body)
        ) as? [String: Any]
        let sentIds = (body?["items"] as? [[String: Any]])?.map { $0["id"] as? String }
        #expect(sentIds == [callerId, mintedId])
        await engine.stop()
    }

    @Test("the edge replay adopts the server's copy of the row")
    func edgeReplayAdoptsTheServerCopy() async throws {
        // No echo on this fixture, deliberately. With one, the event re-lands
        // the same row under the same id and the assertion below holds with
        // the replay's own upsert deleted — so the test would pin the SSE
        // path rather than the replay.
        let (store, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        await engine.setReconnectDelaysForTesting(base: 0.01, max: 0.05)
        let edges = syncedEdges(transport: transport, store: store, queue: queue)

        let created = try await edges.create(
            source: "src", target: "tgt", edgeType: "about"
        )
        // The local write knows no space and stamps its own clock, so a row
        // carrying either of the server's values came from the response.
        #expect(created.spaceId == nil)

        transport.enqueueEvents([])
        transport.enqueue(EdgeResponse(edge: serverCopy(of: created)))

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.awaitCondition(description: "(try? await queue.isEmpty) == true") {
            (try? await queue.isEmpty) == true
        }

        let stored = try await store.fetchEdge(id: created.id)
        #expect(stored.spaceId == EdgeMintingTransport.spaceId)
        #expect(stored.createdAt == EdgeMintingTransport.stampedAt)
        await engine.stop()
    }

    @Test("a repeat the server acknowledges is success, not a decode failure")
    func acknowledgedEdgeRepeatDrainsTheQueue() async throws {
        let (store, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        await engine.setReconnectDelaysForTesting(base: 0.01, max: 0.05)
        let edges = syncedEdges(transport: transport, store: store, queue: queue)

        let created = try await edges.create(
            source: "src", target: "tgt", edgeType: "about"
        )

        // What the server answers when this create already reached it and the
        // response was lost: 200 carrying the stored row and `acknowledged`,
        // where a first arrival gets a 201 carrying the row alone. The test
        // above pins the upsert on the 201 shape; this one pins that the
        // extra key does not turn the answer into a decode failure, which
        // would leave the mutation queued and retrying against a row the
        // server already holds. The server publishes no event for a repeat,
        // so no echo follows and none is modeled — the same as items.
        struct AcknowledgedEdge: Encodable {
            let edge: Edge
            let acknowledged: Bool
        }
        transport.enqueueEvents([])
        transport.enqueue(
            AcknowledgedEdge(edge: serverCopy(of: created), acknowledged: true)
        )

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.awaitCondition(description: "(try? await queue.isEmpty) == true") {
            (try? await queue.isEmpty) == true
        }

        #expect(try await queue.fetchAll().isEmpty)
        let stored = try await store.fetchEdge(id: created.id)
        #expect(stored.spaceId == EdgeMintingTransport.spaceId)
        await engine.stop()
    }

    // MARK: - Cascade drop on permanent createItem failure

    @Test("permanent createItem drop cascades to dependent mutations and purges the local row")
    func createItemCascadeDropsDependents() async throws {
        let (store, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        await engine.setReconnectDelaysForTesting(base: 0.01, max: 0.05)

        // Seed the local store + queue as if the app had created a note,
        // edited it, and spun off a reply edge — all before sync fires.
        // "A" is the note that will fail server-side; "X" and "Y" are
        // unrelated siblings that must survive.
        let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        let ghost = Item(
            createdAt: now, id: "A",
            properties: ["body": .string("")], schemaVersion: 1, source: "test",
            state: .active, tier: .feed, timestamp: now, type: "core.note",
            updatedAt: now, version: 1
        )
        try await store.upsertItem(ghost)
        let survivor = Item(
            createdAt: now, id: "Y",
            properties: ["body": .string("kept")], schemaVersion: 1, source: "test",
            state: .active, tier: .feed, timestamp: now, type: "core.note",
            updatedAt: now, version: 1
        )
        try await store.upsertItem(survivor)
        // The edge the app spun off, as the local store holds it. Without the
        // row there is nothing for the cascade to remove and the assertion
        // below would pass against an absence that was always there.
        try await store.upsertEdge(Edge(
            createdAt: now,
            edgeType: "in-thread",
            id: "E-AX",
            properties: [:],
            sourceId: "A",
            spaceId: nil,
            targetId: "X",
            updatedAt: now,
            version: 1
        ))

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
            createdAt: now, id: "Y",
            properties: ["body": .string("untouched")], schemaVersion: 1, source: "test",
            state: .active, tier: .feed, timestamp: now, type: "core.note",
            updatedAt: now, version: 2
        )
        transport.enqueue(ItemResponse(item: updatedY, metadata: nil))

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.awaitCondition(description: "(try? await queue.isEmpty) == true") {
            (try? await queue.isEmpty) == true
        }

        // Queue is fully drained — A's createItem + cascade dropped,
        // Y's updateItem replayed successfully.

        // Ghost A purged from local store; survivor Y intact.
        let ghostFetch = try? await store.fetchItem(id: "A")
        #expect(ghostFetch == nil)
        let survivorFetch = try await store.fetchItem(id: "Y")
        #expect(survivorFetch.id == "Y")

        // The cascaded edge's local row goes too. Its queue record is dropped
        // rather than refused on its own, so the direct removal path never
        // sees it — and left behind it points at an item that no longer
        // exists on either side.
        #expect((try? await store.fetchEdge(id: "E-AX")) == nil)

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

    // MARK: - SSE reconnect nudge

    @Test("SSE reconnect nudge drains mutations queued after the first replay")
    func sseReconnectDrainsLaterMutations() async throws {
        let (_, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
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
        try await SyncEngineTestKit.awaitCondition(description: "transport.calls.filter { $0.path == \"/events\" }.count >= 1"
        ) {
            await transport.calls.filter { $0.path == "/events" }.count >= 1
        }
        try await SyncEngineTestKit.awaitCondition(description: "connManager.state == .online") {
            connManager.state == .online
        }

        // Now enqueue a mutation AFTER the first replay cycle has
        // already ticked. Without the reconnect nudge, this mutation
        // would sit forever — no network transition will fire.
        try await queue.enqueueDeleteItem(id: "019eb000-0000-7000-8000-000000000042")
        transport.enqueueError(NotFoundError(message: "server gone"))

        // Assert the reconnect nudge re-opens SSE without us manually
        // re-triggering `.connecting`. Wait for the observable effect instead
        // of sampling immediately after the queue drains: proactive replay can
        // empty the queue before the reconnect delay elapses.
        try await SyncEngineTestKit.awaitCondition(description: "transport.calls.filter { $0.path == \"/events\" }.count >= 2"
        ) {
            transport.calls.filter { $0.path == "/events" }.count >= 2
        }

        // The mutation also drains without another reachability transition.
        try await SyncEngineTestKit.awaitCondition(description: "(try? await queue.isEmpty) == true") {
            (try? await queue.isEmpty) == true
        }

        await engine.stop()
    }

    // MARK: - Transient createItem blocks same-item downstream mutations

    @Test("transient createItem blocks downstream deleteItem from running in the same cycle")
    func transientCreateItemBlocksDeleteItemSameCycle() async throws {
        let (store, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        // Compress back-off so cycle 2 fires automatically in tens of ms.
        await engine.setReconnectDelaysForTesting(base: 0.02, max: 0.05)

        // Local state: user created a note and immediately trashed it before
        // any sync fired. The note has never reached the server.
        let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        let itemId = "019ea000-0000-7000-8000-000000000042"
        let localItem = Item(
            createdAt: now, id: itemId,
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
        transport.enqueueError(MarfaError(code: "server_error", message: "transient", status: 500))

        // Cycle 2: createItem succeeds, then deleteItem succeeds.
        transport.enqueueEvents([])
        let serverCreated = Item(
            createdAt: now, id: itemId,
            properties: ["body": .string("new note")], schemaVersion: 1, source: "sdk",
            state: .active, tier: .feed, timestamp: now, type: "core.note", updatedAt: now, version: 1
        )
        transport.enqueue(ItemResponse(item: serverCreated, metadata: nil))
        transport.enqueue(EmptyResponse())

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        // Wait for full drain — both cycles must complete cleanly.
        try await SyncEngineTestKit.awaitCondition(description: "(try? await queue.isEmpty) == true") {
            (try? await queue.isEmpty) == true
        }

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
        let (store, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        await engine.setReconnectDelaysForTesting(base: 0.02, max: 0.05)

        let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        let itemId = "019ea001-0000-7000-8000-000000000043"
        let localItem = Item(
            createdAt: now, id: itemId,
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
        transport.enqueueError(MarfaError(code: "server_error", message: "transient", status: 500))

        // Cycle 2: all three replay in order and succeed.
        transport.enqueueEvents([])
        let serverCreated = Item(
            createdAt: now, id: itemId,
            properties: ["body": .string("draft")], schemaVersion: 1, source: "sdk",
            state: .active, tier: .feed, timestamp: now, type: "core.note", updatedAt: now, version: 1
        )
        transport.enqueue(ItemResponse(item: serverCreated, metadata: nil))
        let serverUpdated = Item(
            createdAt: now, id: itemId,
            properties: ["body": .string("edited")], schemaVersion: 1, source: "sdk",
            state: .active, tier: .feed, timestamp: now, type: "core.note", updatedAt: now, version: 2
        )
        transport.enqueue(ItemResponse(item: serverUpdated, metadata: nil))
        transport.enqueue(MetadataResponse(metadata: Metadata(
            extensions: [:], itemId: itemId, tags: ["note"]
        )))

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.awaitCondition(description: "(try? await queue.isEmpty) == true") {
            (try? await queue.isEmpty) == true
        }

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
        let (store, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        await engine.setReconnectDelaysForTesting(base: 0.02, max: 0.05)

        let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        let itemA = "019ea002-0000-7000-8000-000000000044"
        let itemB = "019ea003-0000-7000-8000-000000000045"

        // Item A: pending create (will fail transiently).
        let itemALocal = Item(
            createdAt: now, id: itemA,
            properties: ["body": .string("A")], schemaVersion: 1, source: "sdk",
            state: .active, tier: .feed, timestamp: now, type: "core.note", updatedAt: now, version: 1
        )
        try await store.upsertItem(itemALocal)
        let createA = CreateItemInput(type: "core.note", properties: ["body": .string("A")], id: itemA)
        try await queue.enqueueCreateItem(createA, localId: itemA)

        // Item B: pre-existing update (must replay in cycle 1 despite A's failure).
        let itemBLocal = Item(
            createdAt: now, id: itemB,
            properties: ["body": .string("B")], schemaVersion: 1, source: "sdk",
            state: .active, tier: .feed, timestamp: now, type: "core.note", updatedAt: now, version: 1
        )
        try await store.upsertItem(itemBLocal)
        try await queue.enqueueUpdateItem(id: itemB, properties: ["body": .string("B updated")])

        // Cycle 1: createItem(A) fails transiently; updateItem(B) must proceed.
        transport.enqueueEvents([])
        transport.enqueueError(MarfaError(code: "server_error", message: "transient", status: 500))
        let updatedB = Item(
            createdAt: now, id: itemB,
            properties: ["body": .string("B updated")], schemaVersion: 1, source: "sdk",
            state: .active, tier: .feed, timestamp: now, type: "core.note", updatedAt: now, version: 2
        )
        transport.enqueue(ItemResponse(item: updatedB, metadata: nil))

        // Cycle 2: createItem(A) succeeds; no more mutations.
        transport.enqueueEvents([])
        let serverA = Item(
            createdAt: now, id: itemA,
            properties: ["body": .string("A")], schemaVersion: 1, source: "sdk",
            state: .active, tier: .feed, timestamp: now, type: "core.note", updatedAt: now, version: 1
        )
        transport.enqueue(ItemResponse(item: serverA, metadata: nil))

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.awaitCondition(description: "(try? await queue.isEmpty) == true") {
            (try? await queue.isEmpty) == true
        }

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
}
