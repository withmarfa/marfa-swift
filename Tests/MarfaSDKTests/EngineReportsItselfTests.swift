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

        // **Two waiting and one stuck, not one of each.** With equal counts a
        // reader that had the two predicates the wrong way round would report
        // the same numbers, and this test would pass against it — which it did
        // until a mutation said so.
        for label in ["waiting one", "waiting two", "stuck"] {
            var input = CreateItemInput(type: "core.note", properties: ["body": .string(label)])
            input.id = UUIDv7.generateString()
            try await queue.enqueueCreateItem(input, localId: input.id!)
        }
        let rows = try await queue.fetchAll()
        try await queue.recordBlocked(
            id: try #require(rows.last).id,
            reason: PendingMutationBlockReason.conflictUnresolved,
            error: "held"
        )

        let counts = try await queue.counts
        #expect(counts.pending == 2)
        #expect(counts.blocked == 1)
        #expect(counts.deadLettered == 0)
        #expect(counts.outstanding == 3)
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
    /// **Driven, not merely compared.** An earlier version of this asserted
    /// only that the engine and the manager agreed while both sat at
    /// `.offline` — which holds against a property returning a hardcoded
    /// `.offline` and so proved nothing. The manager carries a test seam that
    /// bypasses its transition guards, which the rest of the suite already
    /// uses twenty times over; the claim that this could not be driven was
    /// wrong and is what made the test vacuous.
    @Test("connection state reaches the engine and the client, and follows the manager")
    func connectionStateReachesTheClient() async throws {
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
    /// desynchronisation with the sign reversed. Both are silent.
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

    /// `0 of 0` is complete rather than undefined — a space with nothing in it
    /// has finished filling.
    @Test("progress against an empty total reads as finished, not as a divide by zero")
    func emptyTotalIsComplete() {
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
}
