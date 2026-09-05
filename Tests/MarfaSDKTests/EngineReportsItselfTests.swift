import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// **Rule 19: the engine reports itself.** An app had to keep hold of the
/// connection-state object it passed into the synced factory to learn whether
/// it was online, and had to fetch three arrays and measure them to learn how
/// much was outstanding.
///
/// These assert the numbers rather than the plumbing, because a forwarding
/// property that compiles is not evidence it forwards the right thing.
/// Collects hydration endings from a detached watcher.
private actor EndingBox {
    private(set) var seen: [(imported: Int, completed: Bool)] = []
    func add(imported: Int, completed: Bool) { seen.append((imported, completed)) }
}

/// Collects hydration events from a detached watcher.
private actor EventBox {
    private(set) var pairs: [(imported: Int, total: Int)] = []
    func add(imported: Int, total: Int) { pairs.append((imported, total)) }
}

@Suite("The engine reports itself")
struct EngineReportsItselfTests {


    /// A minimal item-with-metadata, local to this suite so it does not depend
    /// on another file's private fixture.
    private func pair(_ id: String) -> ItemWithMetadata {
        ItemWithMetadata(
            item: Item(
                createdAt: "2026-01-01T00:00:00.000Z",
                id: id,
                properties: [:],
                schemaVersion: 1,
                source: "test",
                state: .active, tier: .library,
                timestamp: "2026-01-01T00:00:00.000Z",
                type: "core.note",
                updatedAt: "2026-01-01T00:00:00.000Z",
                version: 1
            ),
            metadata: Metadata(extensions: [:], itemId: id, tags: [])
        )
    }

    // MARK: - Counts

    /// **The three dispositions are different news.** "2 waiting" and
    /// "2 stuck" mean opposite things to a person who could act, and a
    /// consumer given one total cannot tell them apart.
    @Test("the queue reports pending, blocked and dead-lettered separately")
    func queueCountsSeparateTheDispositions() async throws {
        let (_, queue, _, _, engine) = try await SyncEngineTestKit.makeFixture()

        // **Four different counts, no two alike.** Any pair of counters sharing
        // a value can be swapped invisibly, and `outstanding` only catches a
        // swap across the line it draws. The fixture this replaces was two
        // pending and one blocked, which did pin that pair — and left
        // `inFlight` and `deadLettered` both at zero and both unasserted, so
        // either could have been absent. So 2 waiting, 3 in flight, 1 stuck,
        // 4 refused.
        for label in (1...10).map({ "row \($0)" }) {
            var input = CreateItemInput(type: "core.note", properties: ["body": .string(label)])
            input.id = UUIDv7.generateString()
            try await queue.enqueueCreateItem(input, localId: input.id!)
        }
        let rows = try await queue.fetchAll()
        #expect(rows.count == 10)

        for row in rows[2..<5] {
            try await queue.markInFlight(id: row.id)
        }
        try await queue.recordBlocked(
            id: rows[5].id,
            reason: PendingMutationBlockReason.conflictUnresolved,
            error: "held"
        )
        for row in rows[6..<10] {
            try await queue.recordDropped(
                record: row,
                droppedAt: Date(),
                error: MarfaError(code: "validation_error", message: "refused", status: 400)
            )
        }

        let counts = try await queue.counts
        #expect(counts.pending == 2)
        #expect(counts.inFlight == 3)
        #expect(counts.blocked == 1)
        #expect(counts.deadLettered == 4)
        #expect(counts.outstanding == 6, "a dead letter is finished business, not outstanding work")
        #expect(!counts.isSettled)

        // And the engine reports the same numbers, so the forwarding is not
        // quietly reading something else.
        let status = try await engine.status
        #expect(status.queue == counts)
    }

    /// An empty queue is settled, and a dead letter does not unsettle it: a
    /// refusal is finished business, and an app that shows "1 unsent change"
    /// for a write nobody will ever send again is telling someone to wait for
    /// something that will not happen.
    @Test("dead letters do not count as outstanding")
    func deadLettersAreNotOutstanding() {
        let counts = MutationQueueCounts(pending: 0, inFlight: 0, blocked: 0, deadLettered: 3)
        #expect(counts.outstanding == 0)
        #expect(counts.isSettled)
    }

    // MARK: - Connection state

    /// The value an app previously had to keep its own reference to reach.
    ///
    /// **The engine's half only.** This was named for the client too and never
    /// built one, which is exactly how the client's three forwards went
    /// unmeasured — the name read as coverage. They have their own test now.
    ///
    /// **Driven, not merely compared.** An earlier version of this asserted
    /// only that the engine and the manager agreed while both sat at
    /// `.offline` — which holds against a property returning a hardcoded
    /// `.offline` and so proved nothing. The manager carries a test seam that
    /// bypasses its transition guards, which the rest of the suite already
    /// uses twenty times over; the claim that this could not be driven was
    /// wrong and is what made the test vacuous.
    @Test("connection state reaches the engine and follows the manager")
    func connectionStateReachesTheEngine() async throws {
        let (_, _, _, manager, engine) = try await SyncEngineTestKit.makeFixture()
        #expect(engine.connectionState == .offline)

        await manager.applyStateForTesting(.online)
        #expect(engine.connectionState == .online, "the forward reads the manager, not a copy")

        await manager.applyStateForTesting(.syncing)
        #expect(engine.connectionState == .syncing)

        await manager.applyStateForTesting(.offline)
        #expect(engine.connectionState == .offline)
    }

    /// **The stream yields before anything changes, and then on every change.**
    /// A view drawn from it otherwise renders nothing until the connection
    /// next moves, which on a device that is simply online may be never.
    @Test("the connection stream yields the current state and then each change")
    func connectionStreamYieldsCurrentThenChanges() async throws {
        let (_, _, _, manager, engine) = try await SyncEngineTestKit.makeFixture()

        var iterator = engine.connectionStateUpdates.makeAsyncIterator()
        #expect(await iterator.next() == .offline, "a subscriber must not wait for a change")

        await manager.applyStateForTesting(.online)
        #expect(await iterator.next() == .online)

        await manager.applyStateForTesting(.syncing)
        #expect(await iterator.next() == .syncing)
    }

    /// A client with no engine is not offline-with-trouble; it has nowhere to
    /// connect. The stream still finishes rather than hanging a view.
    @Test("a client with no engine reports no status and a stream that ends")
    func aClientWithNoEngineSaysSoRatherThanClaimingHealth() async throws {
        let client = try await MarfaClient.local(path: ":memory:")

        #expect(try await client.syncStatus == nil, "a zeroed status claims health nobody measured")
        #expect(client.connectionState == .offline)

        var yielded = 0
        for await _ in client.connectionStateUpdates { yielded += 1 }
        #expect(yielded == 0, "the stream must finish rather than hang a view awaiting it")
    }

    // MARK: - The double's own contract

    /// **A route the engine reads incidentally must not eat a staged
    /// response.** `MockTransport`'s queue is positional, so answering the
    /// engine from it hands the engine the answer meant for the next request
    /// — and leaving the response in place for later is the same
    /// desynchronization with the sign reversed. Both are silent.
    ///
    /// So a test with responses queued gets a refusal naming the fix. The
    /// engine's own progress read is best-effort and swallows it, which is
    /// why this is asserted through a caller rather than through an import.
    @Test("a queued response is refused rather than handed to an incidental route")
    func anIncidentalRouteRefusesRatherThanStealing() async throws {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MarfaClient(configuration: config, transport: mock)
        mock.enqueue(["some": "unrelated response"])

        await #expect(throws: IncidentalRouteNeedsStagingError.self) {
            _ = try await client.items.stats()
        }
    }

    /// Staged by path, it answers — and keeps answering, because a
    /// bookkeeping route may be read more than once in a run.
    @Test("a route staged by path answers every time")
    func aStagedRouteAnswersRepeatedly() async throws {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MarfaClient(configuration: config, transport: mock)
        mock.stage(["active": 7], for: "/items/stats")

        #expect(try await client.items.stats()["active"] == 7)
        #expect(try await client.items.stats()["active"] == 7)
    }

    // MARK: - Hydration progress

    /// **The import's own reporting, which nothing tested.** Everything else
    /// here is arithmetic on hand-built values; this drives the engine and
    /// reads the events it emitted.
    @Test("a multi-page import reports progress against the server's total")
    func aMultiPageImportReportsProgress() async throws {
        let (_, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.stage(["active": 3], for: "/items/stats")

        let events = engine.events
        let seen = EventBox()
        let watcher = Task {
            for await event in events {
                if case .hydrationProgress(let imported, let total) = event {
                    await seen.add(imported: imported, total: total)
                }
            }
        }
        defer { watcher.cancel() }

        transport.enqueue(PaginatedResult<ItemWithMetadata>(
            data: [pair("i1"), pair("i2")],
            cursor: "c1", hasMore: true
        ))
        transport.enqueue(PaginatedResult<ItemWithMetadata>(
            data: [pair("i3")], cursor: nil, hasMore: false
        ))
        transport.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))

        let imported = try await engine.performInitialSync()
        #expect(imported == 3)

        try await waitUntil(timeout: .seconds(2), description: "both progress events") {
            await seen.pairs.count >= 2
        }
        let pairs = await seen.pairs
        #expect(pairs.map(\.total).allSatisfy { $0 == 3 }, "the denominator is the server's: \(pairs)")
        #expect(pairs.map(\.imported) == pairs.map(\.imported).sorted(), "progress must be monotonic")
        #expect(pairs.last?.imported == 3)

        let status = try await engine.status
        #expect(status.hydration?.imported == 3)
        #expect(status.hydration?.fraction == 1)
    }

    /// **A single-page import asks for no denominator and reports nothing.**
    /// That is the saving the deferral is for — most imports are one page, and
    /// a progress bar for a handful of rows is not worth a round trip.
    @Test("a single-page import makes no stats request and reports no progress")
    func aSinglePageImportSkipsTheDenominator() async throws {
        let (_, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueue(PaginatedResult<ItemWithMetadata>(
            data: [pair("i1")], cursor: nil, hasMore: false
        ))
        transport.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))

        _ = try await engine.performInitialSync()

        #expect(!transport.calls.contains { $0.path == "/items/stats" })
        let status = try await engine.status
        #expect(status.hydration == nil, "no denominator means no progress, not a wrong one")
    }

    /// **A later import must not report an earlier one's numbers.** Without a
    /// reset, a re-import that fits in one page leaves the previous fill's
    /// figures standing — and a stalled fraction reads exactly like an import
    /// still running, which is the one thing a progress bar must not say when
    /// nothing is happening.
    @Test("a second import does not inherit the first one's progress")
    func asecondImportClearsTheFirstsProgress() async throws {
        let (_, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.stage(["active": 3], for: "/items/stats")

        transport.enqueue(PaginatedResult<ItemWithMetadata>(
            data: [pair("i1"), pair("i2")], cursor: "c1", hasMore: true
        ))
        transport.enqueue(PaginatedResult<ItemWithMetadata>(
            data: [pair("i3")], cursor: nil, hasMore: false
        ))
        transport.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))
        _ = try await engine.performInitialSync()
        #expect(try await engine.status.hydration != nil, "the first import should have reported")

        // A second import, one page, so it asks for no denominator.
        transport.enqueue(PaginatedResult<ItemWithMetadata>(
            data: [pair("i4")], cursor: nil, hasMore: false
        ))
        transport.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))
        _ = try await engine.performInitialSync()

        #expect(
            try await engine.status.hydration == nil,
            "the second import inherited the first one's figures"
        )
    }

    /// A server that will not answer the count is a server that can still be
    /// imported from — progress is absent rather than wrong.
    @Test("an unanswerable count leaves progress absent rather than zeroed")
    func anUnanswerableCountReportsNoProgress() async throws {
        let (_, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.stage([String: Int](), for: "/items/stats")
        transport.enqueue(PaginatedResult<ItemWithMetadata>(
            data: [pair("i1")], cursor: "c1", hasMore: true
        ))
        transport.enqueue(PaginatedResult<ItemWithMetadata>(
            data: [pair("i2")], cursor: nil, hasMore: false
        ))
        transport.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))

        _ = try await engine.performInitialSync()

        let status = try await engine.status
        #expect(status.hydration == nil, "an empty answer is not a total of zero")
    }

    /// **`0 of 0` reads as unstarted, not as finished.** Nothing is known and
    /// nothing has arrived, and of the two answers a fraction can give, the
    /// start is the honest one — a full bar over a space nobody has counted
    /// claims a completion that was never measured.
    ///
    /// The name and doc here said the opposite of the assertion below them,
    /// which is worse than either reading on its own: the next person to
    /// notice would have "fixed" the implementation to match the prose.
    @Test("progress against an empty total reads as unstarted, not as a divide by zero")
    func emptyTotalReadsAsUnstarted() {
        #expect(HydrationProgress(imported: 0, total: 0).fraction == 0)
        // Rows against a total of zero saturate rather than divide: the count
        // is the truth and the fraction cannot express it.
        #expect(HydrationProgress(imported: 4, total: 0).fraction == 1)
        #expect(HydrationProgress(imported: 0, total: 10).fraction == 0)
        #expect(HydrationProgress(imported: 5, total: 10).fraction == 0.5)
        #expect(HydrationProgress(imported: 10, total: 10).fraction == 1)
    }

    /// **The total is a snapshot from before the import began**, so a space
    /// written to during a fill can push `imported` past it. Clamping is what
    /// keeps a progress bar from running off the end; `imported` stays honest.
    @Test("progress clamps when the space grew during the import")
    func progressClampsRatherThanOverrunning() {
        let overrun = HydrationProgress(imported: 12, total: 10)
        #expect(overrun.fraction == 1)
        #expect(overrun.imported == 12, "the count stays honest even where the fraction cannot")
    }

    // MARK: - What a report must not survive

    /// **An import that dies partway must not leave a bar standing.** A
    /// fraction frozen at three tenths with nothing running is the one thing a
    /// progress indicator must never say, and it is indistinguishable from an
    /// import still going.
    ///
    /// Clearing at the top of the *next* import does not cover this: there may
    /// be no next import, and the stalled figures stand for the life of the
    /// process. The comment claiming otherwise was wrong about its own
    /// mechanism.
    @Test("an import that fails partway leaves no progress standing")
    func aFailedImportClearsItsProgress() async throws {
        let (_, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.stage(["active": 10], for: "/items/stats")

        // Page one only. The second page finds nothing queued and throws,
        // which is the shape wanted: page one imported and reported, page two
        // died. `enqueueError` cannot express it — the double checks its error
        // queue before anything else, so the error lands on page one and the
        // import never reports at all, which is a test that passes without
        // reaching the defect.
        transport.enqueue(PaginatedResult<ItemWithMetadata>(
            data: [pair("i1"), pair("i2")], cursor: "c1", hasMore: true
        ))

        await #expect(throws: (any Error).self) {
            _ = try await engine.performInitialSync()
        }

        #expect(
            try await engine.status.hydration == nil,
            "2 of 10 with nothing running reads as an import still in flight"
        )
    }

    /// **A route that answers nothing is not a route to keep asking.** The
    /// denominator is bought once; when the answer is unusable the engine
    /// carries on without one rather than paying for the same silence on every
    /// page.
    ///
    /// Three pages, because two give the retry only one opportunity and it
    /// takes two to tell "asked once" from "asked per page".
    @Test("an unanswerable count is asked for once, not once a page")
    func anUnanswerableCountIsAskedForOnce() async throws {
        let (_, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.stage([String: Int](), for: "/items/stats")
        transport.enqueue(PaginatedResult<ItemWithMetadata>(
            data: [pair("i1")], cursor: "c1", hasMore: true
        ))
        transport.enqueue(PaginatedResult<ItemWithMetadata>(
            data: [pair("i2")], cursor: "c2", hasMore: true
        ))
        transport.enqueue(PaginatedResult<ItemWithMetadata>(
            data: [pair("i3")], cursor: nil, hasMore: false
        ))
        transport.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))

        _ = try await engine.performInitialSync()

        let asks = transport.calls.filter { $0.path == "/items/stats" }.count
        #expect(asks == 1, "asked \(asks) times across three pages")
    }

    /// **The client's three forwards, driven through an engine.** Every other
    /// assertion on them lands on the no-engine fallback, which holds against
    /// a client that returns a constant and forwards nothing — so replacing
    /// each of the three with its default left the suite green.
    @Test("the client forwards the engine's own answers rather than a default")
    func theClientForwardsTheEnginesAnswers() async throws {
        let (store, queue, transport, manager, engine) = try await SyncEngineTestKit.makeFixture()
        let client = MarfaClient(
            configuration: ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k"),
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            syncEngine: engine
        )

        await manager.applyStateForTesting(.online)
        #expect(client.connectionState == .online, "the client answered with a default, not the engine")

        var iterator = client.connectionStateUpdates.makeAsyncIterator()
        #expect(await iterator.next() == .online, "the client's stream is not the engine's")
        await manager.applyStateForTesting(.syncing)
        #expect(await iterator.next() == .syncing)

        var input = CreateItemInput(type: "core.note", properties: ["body": .string("queued")])
        input.id = UUIDv7.generateString()
        try await queue.enqueueCreateItem(input, localId: input.id!)

        let status = try #require(try await client.syncStatus, "a client with an engine has a status")
        #expect(status.connection == .syncing, "the status carried a stale or defaulted connection")
        #expect(status.queue.pending == 1, "the status is not reading this client's queue")
    }

    /// **The two fields nothing asserted.** `connection` and
    /// `lastCleanDrainAt` were carried through `status` untested, so either
    /// could have been replaced by a constant without a red.
    @Test("the status carries the live connection and the recorded drain")
    func statusCarriesConnectionAndDrain() async throws {
        let (_, queue, _, manager, engine) = try await SyncEngineTestKit.makeFixture()

        #expect(try await engine.status.lastCleanDrainAt == nil, "nothing has drained yet")

        await manager.applyStateForTesting(.online)
        #expect(try await engine.status.connection == .online)

        let stamp = Date(timeIntervalSince1970: 1_757_000_000)
        try await queue.saveSyncState(
            key: "last_clean_drain_at",
            value: stamp.ISO8601Format(.init(includingFractionalSeconds: true))
        )
        let recorded = try #require(try await engine.status.lastCleanDrainAt)
        #expect(abs(recorded.timeIntervalSince(stamp)) < 0.01)

        await manager.applyStateForTesting(.offline)
        #expect(try await engine.status.connection == .offline, "the status cached a state it should read")
    }

    /// **A queued error belongs to the request the test staged it for.** The
    /// double checks its error queue before it recognizes an incidental route,
    /// so a bookkeeping read the engine makes for itself consumes the head of
    /// that queue — the same desynchronization the path-keyed slot exists to
    /// prevent, left open on the adjacent queue.
    @Test("an incidental route does not consume a queued error")
    func anIncidentalRouteLeavesTheErrorQueueAlone() async throws {
        let mock = MockTransport()
        let client = MarfaClient(
            configuration: ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k"),
            transport: mock
        )
        mock.stage(["active": 7], for: "/items/stats")
        mock.enqueueError(MarfaError(code: "server_error", message: "meant for the list", status: 500))

        #expect(try await client.items.stats()["active"] == 7, "the staged answer, not the error")

        await #expect(throws: MarfaError.self) {
            _ = try await client.items.list()
        }
    }

    /// **The clear has to cover the whole import, not the item loop.** Items
    /// page, then prune, then edges — a throw anywhere after the last progress
    /// event leaves the same stalled fraction, and only the item loop was
    /// driven. This one gets its items and then finds no edge page.
    @Test("an import that dies after the items still leaves no progress standing")
    func aFailureAfterTheItemsAlsoClearsProgress() async throws {
        let (_, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.stage(["active": 10], for: "/items/stats")

        transport.enqueue(PaginatedResult<ItemWithMetadata>(
            data: [pair("i1"), pair("i2")], cursor: "c1", hasMore: true
        ))
        transport.enqueue(PaginatedResult<ItemWithMetadata>(
            data: [pair("i3")], cursor: nil, hasMore: false
        ))
        // No edge page queued, so `/edges` is where this one dies.

        await #expect(throws: (any Error).self) {
            _ = try await engine.performInitialSync()
        }

        #expect(
            try await engine.status.hydration == nil,
            "the clear covers the item loop and stops there"
        )
    }

    /// **A consumer watching events is told the fill stopped.** Clearing
    /// `status` alone left the two surfaces contradicting each other: the pull
    /// surface said no import, the push surface's last word was 2 of 10, and
    /// the push surface is the one a progress bar is built on.
    @Test("a failed import ends its hydration on the event stream too")
    func aFailedImportEndsHydrationOnTheEventStream() async throws {
        let (_, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.stage(["active": 10], for: "/items/stats")
        transport.enqueue(PaginatedResult<ItemWithMetadata>(
            data: [pair("i1"), pair("i2")], cursor: "c1", hasMore: true
        ))

        let events = engine.events
        let endings = EndingBox()
        let watcher = Task {
            for await event in events {
                if case .hydrationEnded(let imported, let completed) = event {
                    await endings.add(imported: imported, completed: completed)
                }
            }
        }
        defer { watcher.cancel() }

        await #expect(throws: (any Error).self) {
            _ = try await engine.performInitialSync()
        }

        try await waitUntil(timeout: .seconds(2), description: "the hydration ending") {
            await endings.seen.count >= 1
        }
        let seen = await endings.seen
        #expect(seen.count == 1, "one ending per import: \(seen)")
        #expect(seen.first?.completed == false, "the import did not finish")
        #expect(seen.first?.imported == 2, "it carries what had landed")
    }

    /// And the ordinary case says so too, so a consumer has one signal for
    /// "stopped" rather than one for failure and silence for success.
    @Test("a finished import ends its hydration as completed")
    func aFinishedImportEndsHydrationAsCompleted() async throws {
        let (_, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.stage(["active": 3], for: "/items/stats")
        transport.enqueue(PaginatedResult<ItemWithMetadata>(
            data: [pair("i1"), pair("i2")], cursor: "c1", hasMore: true
        ))
        transport.enqueue(PaginatedResult<ItemWithMetadata>(
            data: [pair("i3")], cursor: nil, hasMore: false
        ))
        transport.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))

        let events = engine.events
        let endings = EndingBox()
        let watcher = Task {
            for await event in events {
                if case .hydrationEnded(let imported, let completed) = event {
                    await endings.add(imported: imported, completed: completed)
                }
            }
        }
        defer { watcher.cancel() }

        #expect(try await engine.performInitialSync() == 3)

        try await waitUntil(timeout: .seconds(2), description: "the hydration ending") {
            await endings.seen.count >= 1
        }
        let seen = await endings.seen
        #expect(seen.first?.completed == true)
        #expect(seen.first?.imported == 3)
    }

    /// **The engine's own bookkeeping read must not eat a queued error
    /// either.** The staged case is covered above and pins only that the
    /// staged slot outranks the error queue. This one leaves `/items/stats`
    /// unstaged, which is the path the engine actually takes when a test has
    /// no opinion about it — and is where moving the error check back between
    /// the staged slot and the incidental branch would still be wrong while
    /// the other test stayed green.
    @Test("an unstaged incidental read does not consume a queued error")
    func anUnstagedIncidentalReadLeavesTheErrorQueueAlone() async throws {
        let mock = MockTransport()
        let client = MarfaClient(
            configuration: ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k"),
            transport: mock
        )
        mock.enqueueError(MarfaError(code: "server_error", message: "meant for the list", status: 500))

        // Nothing staged for it, and no responses queued, so the double answers
        // the incidental route from its own empty object rather than reaching
        // for the error.
        _ = try await client.items.stats()

        await #expect(throws: MarfaError.self) {
            _ = try await client.items.list()
        }
    }
}
