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

        try await SyncEngineTestKit.awaitCondition(description: "the server's items to reach a store that has never synced") {
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
        try await SyncEngineTestKit.awaitCondition(description: "the stream to open after the import") {
            transport.calls.contains { $0.path == "/events" }
        }
        // No other call: the two import passes, then the stream.
        #expect(transport.calls.map(\.path) == ["/items", "/edges", "/events"])

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
        try await SyncEngineTestKit.awaitCondition(description: "the engine to open its event stream") {
            await transport.openStreamCount >= 1
        }

        // Against a live server the stream does not close, so nothing behind a
        // close can be what moves this. An app watching `FullSyncStateQuery`
        // through its first sync would otherwise sit on "waiting for first
        // sync" with a full library already on screen.
        try await SyncEngineTestKit.awaitCondition(description: "the store to report itself synced while its stream is still open") {
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
        try await SyncEngineTestKit.awaitCondition(description: "the first cycle to import and then open its stream") {
            itemGets(transport) == 1 && transport.calls.contains { $0.path == "/events" }
        }
        await engine.stop()

        // Second lifecycle on the same store. The decision is taken from a
        // difference the store carries, so it has to come out the other way
        // now — otherwise every reconnect re-imports the whole library.
        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.awaitCondition(description: "the second cycle to open its own stream") {
            transport.calls.filter { $0.path == "/events" }.count >= 2
        }

        #expect(itemGets(transport) == 1)
        await engine.stop()
    }

    @Test("a write queued before the first start replays ahead of the import")
    func aQueuedWriteReplaysAheadOfTheImport() async throws {
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

        let input = CreateItemInput(
            type: "core.note", properties: ["body": .string("written before the engine ran")]
        )
        try await queue.enqueueCreateItem(input, localId: "local-1")

        try await transport.enqueue(ItemResponse(item: item("local-1"), metadata: nil))
        try await transport.enqueue(itemPage(["local-1"]))
        try await transport.enqueue(edgePage([]))
        // Stand between the drain and the import.
        await transport.holdNextRequest(method: .get, path: "/items")

        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.awaitCondition(description: "the drain to finish and the import to reach the server") {
            await transport.heldRequestReached
        }

        // The drain has completed and the import has not. A drain is not a
        // sync on a store that has never imported: reporting `.synced` here
        // tells an app it is up to date while its library is still empty.
        let midway = await engine.fullSyncState
        if case .synced = midway {
            Issue.record("reported .synced after the drain but before the import")
        }
        await transport.releaseHeldRequest()

        try await SyncEngineTestKit.awaitCondition(description: "the import to finish and the stream to open") {
            await transport.calls.contains { $0.path == "/events" }
        }

        // Order, not merely presence. The import replaces every row it
        // receives with no version check, so importing first would overwrite
        // the queued write with the server's older body — and importing at all
        // depends on the drain having emptied the queue, because the import
        // refuses over pending work. The stream comes last for the same
        // reason the catch-up exists: it carries nothing that came before it.
        let sent = await transport.calls.map { "\($0.method.rawValue) \($0.path)" }
        let replayed = sent.firstIndex(of: "POST /items")
        let imported = sent.firstIndex(of: "GET /items")
        let streamed = sent.firstIndex(of: "GET /events")
        #expect(replayed != nil, "the queued create should have replayed")
        #expect(imported != nil, "the import should have run rather than refusing")
        #expect(streamed != nil, "the stream should have opened")
        if let replayed, let imported, let streamed {
            #expect(replayed < imported, "the drain has to precede the import: \(sent)")
            #expect(imported < streamed, "the import has to precede the stream: \(sent)")
        }
        #expect(try await engine.hasPendingMutations == false)

        await transport.finishOpenStreams()
        await engine.stop()
    }

    // MARK: - One catch-up at a time

    @Test("an explicit import arriving while the engine is catching up joins it")
    func explicitImportJoinsTheCatchUp() async throws {
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
        await transport.failOnConcurrentRequest(method: .get, path: "/items")
        try await transport.enqueue(itemPage(["i1", "i2"]))
        try await transport.enqueue(edgePage([]))
        await transport.holdNextRequest(method: .get, path: "/items")

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        // The catch-up's import is now suspended inside GET /items, which is
        // the window a consumer's own call lands in: both apps call the import
        // themselves today, and those calls do not go away the day the engine
        // starts making it too.
        try await SyncEngineTestKit.awaitCondition(description: "the catch-up to reach GET /items") {
            await transport.heldRequestReached
        }

        async let explicit = engine.performInitialSync()
        // Both callers have to be inside before the release, or the second
        // one merely arrives after the first finished and joins nothing.
        try await SyncEngineTestKit.awaitCondition(description: "the explicit caller to reach the import as well") {
            await engine.importCallerCountForTesting == 2
        }
        await transport.releaseHeldRequest()

        // The joiner is handed the run's own result rather than a zero or a
        // second pass: two callers, one import, one answer.
        let imported = try await explicit
        #expect(imported == 2, "the joiner should get the import's count; got \(imported)")
        let gets = await transport.calls.filter { $0.path == "/items" && $0.method == .get }
        #expect(gets.count == 1, "expected one import for the two callers; got \(gets.count)")

        await transport.finishOpenStreams()
        await engine.stop()
    }

    @Test("an explicit import refuses over a queued write even when it would join a running one")
    func explicitImportRefusesRatherThanJoining() async throws {
        // Joining must not become the way around the refusal. The owner checks
        // the queue once, inside its own run; a caller that queued a write
        // after that check is still asking to overwrite it.
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
        await transport.holdNextRequest(method: .get, path: "/items")

        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.awaitCondition(description: "the catch-up to reach GET /items") {
            await transport.heldRequestReached
        }

        // A write lands after the running import already asked the queue.
        try await queue.enqueueDeleteItem(id: "server-1")

        await #expect(throws: InitialSyncError.self) {
            _ = try await engine.performInitialSync()
        }

        await transport.releaseHeldRequest()
        await transport.finishOpenStreams()
        await engine.stop()
    }

    @Test("a drain that leaves work behind keeps its own error rather than the import's refusal")
    func aDrainThatLeavesWorkKeepsItsError() async throws {
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

        try await queue.enqueueDeleteItem(id: "server-1")
        // Transient, so the row survives the drain and the queue is still not
        // empty when the import would run.
        await transport.enqueueError(
            MarfaError(code: "server_error", message: "upstream is unwell", status: 503)
        )

        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.awaitCondition(description: "the failed drain to be reported") {
            if case .failed = await engine.fullSyncState { return true }
            return false
        }

        // The import would refuse over the row the drain could not clear, and
        // that refusal would stand in `fullSyncState` where the drain's error
        // belongs — naming the consequence and hiding the cause. It is not
        // attempted at all.
        let state = await engine.fullSyncState
        if case .failed(_, let error) = state {
            #expect(
                !(error is InitialSyncError),
                "the import's refusal replaced the drain's error: \(error)"
            )
        }
        let asked = await transport.calls.contains { $0.path == "/items" && $0.method == .get }
        #expect(!asked, "the import should not have been attempted over an undrained queue")

        await transport.finishOpenStreams()
        await engine.stop()
    }

    @Test("a write that failed to replay does not make the device re-import its library")
    func aFailedWriteDoesNotTriggerAReimport() async throws {
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

        try await queue.enqueueDeleteItem(id: "server-1")
        await transport.enqueueError(
            MarfaError(code: "server_error", message: "upstream is unwell", status: 503)
        )

        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.awaitCondition(description: "the drain to fail and be reported") {
            if case .failed = await engine.fullSyncState { return true }
            return false
        }

        // The write is abandoned, so the next cycle has an empty queue and a
        // failure still standing against it.
        let rows = try await queue.fetchAll()
        for row in rows { try await queue.remove(id: row.id) }

        await transport.finishOpenStreams()
        await connManager.applyStateForTesting(.offline)
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.awaitCondition(description: "the next cycle to open its own stream") {
            await transport.calls.filter { $0.path == "/events" }.count >= 2
        }

        // Whether this device needs the library is a question about the
        // library, and a write that would not send says nothing about it.
        // Deciding from the reported sync state instead would have a device
        // re-download everything it owns because one mutation failed.
        let asked = await transport.calls.contains { $0.path == "/items" && $0.method == .get }
        #expect(!asked, "a failed write should not trigger a full re-import")

        await transport.finishOpenStreams()
        await engine.stop()
    }

    @Test("stop() does not wait for an import in flight")
    func stopDoesNotWaitForAnImport() async throws {
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
        await transport.holdNextRequest(method: .get, path: "/items")

        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.awaitCondition(description: "the import to reach the server and stay there") {
            await transport.heldRequestReached
        }

        // Never released. `stop()` documents itself as a quiescence boundary,
        // and an import is unstructured and can page a whole library — so if
        // it is awaited rather than cancelled this call never returns and the
        // suite's time limit is what ends the test.
        await engine.stop()

        #expect(await engine.isRunningForTesting == false)
        await transport.releaseHeldRequest()
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
        try await SyncEngineTestKit.awaitCondition(description: "the engine to open its event stream") {
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
        try await SyncEngineTestKit.awaitCondition(description: "the next online cycle to import what the failed one did not") {
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

        try await SyncEngineTestKit.awaitCondition(description: "the write queued while the engine was stopped to replay") {
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
            connectionManager: connManager,
            // A millisecond, so the debounce is nowhere near the window below
            // that has to outlast it — otherwise the test measures the two
            // against each other rather than the drop it is about.
            drainDebounceInterval: .milliseconds(1)
        )
        await suppressReconnect(engine)
        try await transport.enqueue(itemPage(["i1"]))
        try await transport.enqueue(edgePage([]))
        try await transport.enqueue(EmptyResponse())
        // Stand inside the first import, which is where someone opening the
        // app writes: the store is filling and the stream is not up yet.
        await transport.holdNextRequest(method: .get, path: "/items")

        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.awaitCondition(description: "the first import to reach the server") {
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

        try await SyncEngineTestKit.awaitCondition(description: "the write made during the import to replay once the engine is online") {
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
        try await SyncEngineTestKit.awaitCondition(description: "the engine to open its event stream") {
            await transport.openStreamCount >= 1
        }

        // The ordinary case: the app is open, the stream is up, and someone
        // edits something. Waited out to `.online` rather than to the stream
        // registering, because that is the precondition the case rests on —
        // the proactive drain is gated on it, and an engine that treats an
        // open stream as still connecting never gets there at all.
        try await SyncEngineTestKit.awaitCondition(description: "the engine to report itself online while its stream is open") {
            connManager.state == .online
        }

        try await transport.enqueue(EmptyResponse())
        try await queue.enqueueDeleteItem(id: "server-2")

        try await SyncEngineTestKit.awaitCondition(description: "the write made during the stream to replay while it is still open") {
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
        try await SyncEngineTestKit.awaitCondition(description: "the path monitor to deliver its first update") {
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

        // The premise is that nothing moves the manager off `.online` by
        // itself. `NWPathMonitor` delivers on path changes, and one arriving
        // in this window would open the stream for its own reasons and make
        // the test pass without the engine having done anything.
        let premise = connManager.state
        if premise != .online {
            Issue.record("the manager left .online before start(), so this proves nothing")
        }

        await engine.start()

        try await SyncEngineTestKit.awaitCondition(description: "the engine to open a stream against an already-online manager") {
            transport.calls.contains { $0.path == "/events" }
        }
        #expect(itemGets(transport) == 1, "the same entry has to run the catch-up")
        await engine.stop()
    }

    @Test("start() nudges a manager that is online and leaves any other state alone")
    func startOnlyNudgesAnOnlineManager() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        await connManager.start()
        try await SyncEngineTestKit.awaitCondition(description: "the path monitor to deliver its first update") {
            connManager.state != .offline
        }
        // Mid-drain rather than online. The nudge exists for a manager parked
        // on `.online` with nothing left to move it; firing it here would
        // reopen a stream over a cycle that is still running.
        await connManager.applyStateForTesting(.syncing)

        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        await suppressReconnect(engine)

        await engine.start()

        #expect(connManager.state == .syncing, "start() moved a manager it should have left alone")
        try await SyncEngineTestKit.expectRemainsFalse(for: .milliseconds(300)) {
            transport.calls.contains { $0.path == "/events" }
        }
        await engine.stop()
    }
}
