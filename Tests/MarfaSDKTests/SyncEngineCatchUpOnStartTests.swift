import Foundation
import Testing
@testable import MarfaSDK
import MarfaSDKTestSupport

/// What the engine does when it comes online.
///
/// `start()` used to begin watching the network, open the event stream and
/// nothing else, which left two holes with one shape. A store that had never
/// synced stayed empty, because the stream carries only what happens after it
/// opens and the import was a separate call the documented setup never made.
/// And a write queued while the engine was stopped sat unsent, because the
/// only two things that drain the queue are a ping from a fresh enqueue, which
/// a listener that is not yet subscribed never sees, and the stream closing,
/// which against a live server does not happen.
///
/// Both are the same missing step: nothing brought the store level with the
/// server before the stream opened.
@Suite("The engine catches up when it comes online", .timeLimit(.minutes(1)))
struct SyncEngineCatchUpOnStartTests {

    // MARK: - Fixtures

    private func item(_ id: String, body: String = "b") -> Item {
        Item(
            createdAt: "2026-09-02T09:00:00Z",
            id: id,
            properties: ["body": .string(body)],
            schemaVersion: 1,
            source: "test",
            state: .active,
            tier: .feed,
            timestamp: "2026-09-02T09:00:00Z",
            type: "core.note",
            updatedAt: "2026-09-02T09:00:00Z",
            version: 1
        )
    }

    private func pair(_ id: String) -> ItemWithMetadata {
        ItemWithMetadata(
            item: item(id),
            metadata: Metadata(extensions: [:], itemId: id, tags: [])
        )
    }

    private func edge(_ id: String, from source: String, to target: String) -> Edge {
        Edge(
            createdAt: "2026-09-02T09:00:00Z",
            edgeType: "core.about",
            id: id,
            properties: [:],
            sourceId: source,
            targetId: target,
            updatedAt: "2026-09-02T09:00:00Z"
        )
    }

    private func itemPage(_ ids: [String]) -> PaginatedResult<ItemWithMetadata> {
        PaginatedResult<ItemWithMetadata>(data: ids.map(pair), cursor: nil, hasMore: false)
    }

    private func edgePage(_ edges: [Edge]) -> PaginatedResult<Edge> {
        PaginatedResult<Edge>(data: edges, cursor: nil, hasMore: false)
    }

    /// Every wait here is a readiness gate rather than a claim about speed:
    /// what these tests are about is a write or an import that never happens
    /// at all, which no budget bounds. Five seconds is the headroom
    /// `MarfaSDKTestSupport.waitUntil` already documents for hosts that run
    /// several times slower than local Apple silicon — a tighter one would be
    /// measuring the runner, and this suite shares its cores with CI.
    ///
    /// Pushes the reconnect nudge past the end of the test. Every assertion
    /// here is about one cycle, and a second cycle arriving mid-assertion
    /// would let a passing run and a failing one produce the same transcript.
    private func suppressReconnect(_ engine: SyncEngine) async {
        await engine.setReconnectDelaysForTesting(base: 60, max: 60)
    }

    private func itemGets(_ transport: MockTransport) -> Int {
        transport.calls.filter { $0.path == "/items" && $0.method == .get }.count
    }

    // MARK: - Hydration

    @Test("a fresh store fills itself from the server when the engine starts")
    func aFreshStoreFillsItselfOnStart() async throws {
        let (store, _, transport, connManager, engine) =
            try await SyncEngineTestKit.makeFixture(hasImportedBefore: false)
        await suppressReconnect(engine)
        transport.enqueue(itemPage(["i1", "i2"]))
        transport.enqueue(edgePage([edge("e1", from: "i1", to: "i2")]))

        // `start()` and nothing else, because that is the setup the README and
        // the published SDK page show.
        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the server's items to reach a store that has never synced"
        ) {
            let stored = try await store.fetchItems(filters: nil)
            return Set(stored.data.map(\.id)) == ["i1", "i2"]
        }

        // Edges on the same pass. A store with items and no edges shows a
        // library where nothing is related to anything.
        let edges = try await store.fetchEdges(edgeType: nil, cursor: nil, limit: nil)
        #expect(edges.data.map(\.id) == ["e1"])

        // The import lands before the stream is asked for, so the call log is
        // waited out to the stream rather than read at the import — otherwise
        // "no other call" is asserted against a cycle still in progress.
        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the stream to open after the import"
        ) {
            transport.calls.contains { $0.path == "/events" }
        }
        // No other call: the two import passes, then the stream.
        #expect(transport.calls.map(\.path) == ["/items", "/edges", "/events"])

        // Waited rather than sampled: `fullSyncState` reports `.syncing`
        // for as long as a drain cycle is in flight, and the cycle that
        // follows the import is one. A single read races it.
        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the store to report itself synced after its first import"
        ) {
            if case .synced = await engine.fullSyncState { return true }
            return false
        }
        await engine.stop()
    }

    @Test("a fresh store reports itself synced once the import lands, with the stream still open")
    func aFreshStoreReportsSyncedWhileTheStreamIsOpen() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        let transport = HeldOpenStreamTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        await suppressReconnect(engine)
        try await transport.enqueue(itemPage(["i1"]))
        try await transport.enqueue(edgePage([]))

        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the engine to open its event stream"
        ) {
            await transport.openStreamCount >= 1
        }

        // Against a live server the stream does not close, so nothing behind a
        // close can be what moves this. An app watching `FullSyncStateQuery`
        // through its first sync would otherwise sit on "waiting for first
        // sync" with a full library already on screen.
        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the store to report itself synced while its stream is still open"
        ) {
            if case .synced = await engine.fullSyncState { return true }
            return false
        }
        let streamStillOpen = await transport.openStreamsFinished == false
        #expect(streamStillOpen, "the state must not depend on the stream closing")

        await transport.finishOpenStreams()
        await engine.stop()
    }

    @Test("a store that has already imported does not import again on the next start")
    func aSyncedStoreDoesNotImportAgain() async throws {
        let (_, _, transport, connManager, engine) =
            try await SyncEngineTestKit.makeFixture(hasImportedBefore: false)
        await suppressReconnect(engine)
        transport.enqueue(itemPage(["i1"]))
        transport.enqueue(edgePage([]))

        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the first cycle to import and then open its stream"
        ) {
            itemGets(transport) == 1 && transport.calls.contains { $0.path == "/events" }
        }
        await engine.stop()

        // Second lifecycle on the same store. The decision is taken from a
        // difference the store carries, so it has to come out the other way
        // now — otherwise every reconnect re-imports the whole library.
        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the second cycle to open its own stream"
        ) {
            transport.calls.filter { $0.path == "/events" }.count >= 2
        }

        #expect(itemGets(transport) == 1)
        await engine.stop()
    }

    @Test("a write queued before the first start replays ahead of the import")
    func aQueuedWriteReplaysAheadOfTheImport() async throws {
        let (_, queue, transport, connManager, engine) =
            try await SyncEngineTestKit.makeFixture(hasImportedBefore: false)
        await suppressReconnect(engine)

        let input = CreateItemInput(
            type: "core.note", properties: ["body": .string("written before the engine ran")]
        )
        try await queue.enqueueCreateItem(input, localId: "local-1")

        transport.enqueue(ItemResponse(item: item("local-1"), metadata: nil))
        transport.enqueue(itemPage(["local-1"]))
        transport.enqueue(edgePage([]))

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the import to run after the queue drained"
        ) {
            itemGets(transport) == 1
        }

        // Order, not merely presence. The import replaces every row it
        // receives with no version check, so importing first would overwrite
        // the queued write with the server's older body — and importing at
        // all depends on the drain having emptied the queue, because the
        // import refuses over pending work.
        let sent = transport.calls.map { "\($0.method.rawValue) \($0.path)" }
        let replayed = sent.firstIndex(of: "POST /items")
        let imported = sent.firstIndex(of: "GET /items")
        #expect(replayed != nil, "the queued create should have replayed")
        #expect(imported != nil, "the import should have run rather than refusing")
        if let replayed, let imported {
            #expect(replayed < imported, "the drain has to precede the import: \(sent)")
        }
        #expect(try await engine.hasPendingMutations == false)
        await engine.stop()
    }

    // MARK: - One catch-up at a time

    @Test("an explicit import arriving while the engine is catching up joins it")
    func explicitImportJoinsTheCatchUp() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        let transport = BlockingTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        await suppressReconnect(engine)

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        // The catch-up's import is now suspended inside GET /items, which is
        // the window a consumer's own call lands in: both apps call the import
        // themselves today, and the call does not go away the day the engine
        // starts doing it too.
        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the catch-up to reach GET /items"
        ) {
            await transport.itemsCallCount >= 1
        }

        async let explicit = engine.performInitialSync()
        try await SyncEngineTestKit.expectRemainsFalse(for: .milliseconds(200)) {
            await transport.itemsCallCount > 1
        }
        await transport.release(result: itemPage([]))
        _ = try await explicit

        let count = await transport.itemsCallCount
        #expect(count == 1, "expected one import for the two callers; got \(count)")
        await engine.stop()
    }

    @Test("two starts racing each other produce one import")
    func twoConcurrentStartsProduceOneImport() async throws {
        let (_, _, transport, connManager, engine) =
            try await SyncEngineTestKit.makeFixture(hasImportedBefore: false)
        await suppressReconnect(engine)
        transport.enqueue(itemPage(["i1"]))
        transport.enqueue(edgePage([]))

        async let first: Void = engine.start()
        async let second: Void = engine.start()
        _ = await (first, second)
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the import to run"
        ) {
            itemGets(transport) == 1
        }
        try await SyncEngineTestKit.expectRemainsFalse(for: .milliseconds(200)) {
            itemGets(transport) > 1
        }
        await engine.stop()
    }

    @Test("an explicit import over a queue that has not drained still refuses")
    func explicitImportStillRefusesOverAQueuedWrite() async throws {
        // The coalescer must not become a way around the refusal: a caller
        // that asks directly is still asking to overwrite local work.
        let (_, queue, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await queue.enqueueDeleteItem(id: "server-1")

        await #expect(throws: InitialSyncError.self) {
            _ = try await engine.performInitialSync()
        }
    }

    // MARK: - A failed import

    @Test("an import that fails stays visible, the stream opens anyway, and the next cycle tries again")
    func aFailedImportRetriesOnTheNextCycle() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        let transport = HeldOpenStreamTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        await suppressReconnect(engine)
        await transport.enqueueError(
            NetworkError(URLError(.networkConnectionLost))
        )

        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the engine to open its event stream"
        ) {
            await transport.openStreamCount >= 1
        }

        // The stream opens regardless of the import, because a device whose
        // import failed should not also be deaf to what happens next.
        let state = await engine.fullSyncState
        guard case .failed = state else {
            Issue.record("expected .failed after the import failed, got \(state)")
            await transport.finishOpenStreams()
            await engine.stop()
            return
        }

        try await transport.enqueue(itemPage(["i1"]))
        try await transport.enqueue(edgePage([]))
        await transport.finishOpenStreams()
        await connManager.applyStateForTesting(.offline)
        await connManager.applyStateForTesting(.connecting)

        // Waited on what the retry puts in the store rather than on another
        // GET appearing: the failed attempt already left one of those in the
        // call log, so a wait on presence would pass without a retry.
        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the next online cycle to import what the failed one did not"
        ) {
            let stored = try await store.fetchItems(filters: nil)
            return stored.data.map(\.id) == ["i1"]
        }

        await transport.finishOpenStreams()
        await engine.stop()
    }

    // MARK: - Draining without a stream close

    @Test("a write queued while the engine was stopped replays without waiting for the stream to close")
    func aWriteQueuedWhileStoppedReplaysOnStart() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let transport = HeldOpenStreamTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        await suppressReconnect(engine)

        // The app wrote while it was offline and was then closed. Nothing is
        // listening for the enqueue ping, and the stream this reopens onto
        // will not close on its own.
        try await queue.enqueueDeleteItem(id: "server-1")
        try await transport.enqueue(EmptyResponse())

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the write queued while the engine was stopped to replay"
        ) {
            try await engine.hasPendingMutations == false
        }

        let replayed = await transport.calls.contains {
            $0.path == "/items/server-1" && $0.method == .delete
        }
        #expect(replayed)
        let streamStillOpen = await transport.openStreamsFinished == false
        #expect(streamStillOpen, "the replay must not depend on the stream closing")

        await transport.finishOpenStreams()
        await engine.stop()
    }

    @Test("a write made while the engine is still coming online is replayed once it is")
    func aWriteMadeWhileComingOnlineIsReplayed() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        let transport = HeldOpenStreamTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        await suppressReconnect(engine)
        try await transport.enqueue(itemPage(["i1"]))
        try await transport.enqueue(edgePage([]))
        try await transport.enqueue(EmptyResponse())
        // Stand inside the first import, which is where someone opening the
        // app writes: the store is filling and the stream is not up yet.
        await transport.holdNextRequest(path: "/items")

        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the first import to reach the server"
        ) {
            await transport.heldRequestReached
        }

        try await queue.enqueueDeleteItem(id: "server-3")

        // The ping this enqueue sends is spent against a gate that only opens
        // on `.online`, and the engine does not read online until the stream
        // is up. Nothing replays it, which is what the wait after the release
        // then has to recover from.
        try await SyncEngineTestKit.expectRemainsFalse(for: .milliseconds(300)) {
            await transport.calls.contains { $0.method == .delete }
        }
        await transport.releaseHeldRequest()

        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the write made during the import to replay once the engine is online"
        ) {
            try await engine.hasPendingMutations == false
        }
        let streamStillOpen = await transport.openStreamsFinished == false
        #expect(streamStillOpen, "the replay must not depend on the stream closing")

        await transport.finishOpenStreams()
        await engine.stop()
    }

    @Test("a write made while the stream is open replays without waiting for it to close")
    func aWriteMadeWhileTheStreamIsOpenReplays() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let transport = HeldOpenStreamTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager,
            drainDebounceInterval: .milliseconds(20)
        )
        await suppressReconnect(engine)

        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the engine to open its event stream"
        ) {
            await transport.openStreamCount >= 1
        }

        // The ordinary case: the app is open, the stream is up, and someone
        // edits something. Waited out to `.online` rather than to the stream
        // registering, because that is the precondition the case rests on —
        // the proactive drain is gated on it, and an engine that treats an
        // open stream as still connecting never gets there at all.
        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the engine to report itself online while its stream is open"
        ) {
            connManager.state == .online
        }

        try await transport.enqueue(EmptyResponse())
        try await queue.enqueueDeleteItem(id: "server-2")

        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the write made during the stream to replay while it is still open"
        ) {
            try await engine.hasPendingMutations == false
        }
        let streamStillOpen = await transport.openStreamsFinished == false
        #expect(streamStillOpen, "the replay must not depend on the stream closing")

        await transport.finishOpenStreams()
        await engine.stop()
    }

    // MARK: - Coming up against a manager that is already online

    @Test("an engine started on a manager that is already online opens a stream and catches up")
    func startOnAnAlreadyOnlineManagerOpensAStream() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        let transport = MockTransport()
        let connManager = ConnectionStateManager()

        // A synced client can be handed a manager the app already started and
        // already reads. `ConnectionStateManager.start()` is idempotent, so
        // the engine's own call installs no second monitor and no fresh path
        // update arrives to move the state off `.online`.
        await connManager.start()
        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the path monitor to deliver its first update"
        ) {
            connManager.state != .offline
        }
        await connManager.applyStateForTesting(.online)

        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        await suppressReconnect(engine)
        transport.enqueue(itemPage(["i1"]))
        transport.enqueue(edgePage([]))

        await engine.start()

        try await SyncEngineTestKit.waitUntil(
            timeout: .seconds(5),
            description: "the engine to open a stream against an already-online manager"
        ) {
            transport.calls.contains { $0.path == "/events" }
        }
        #expect(itemGets(transport) == 1, "the same entry has to run the catch-up")
        await engine.stop()
    }
}
