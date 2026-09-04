import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// A bulk action on a client with a store resolves its own match set, and both
/// halves of that have to be right: the narrowing it applies must be the
/// narrowing it was given, and every refusal must happen before a row is
/// touched.
///
/// Dropping a narrowing is defensible for a listing — an over-wide read shows
/// extra rows and the next read corrects it. A bulk action is not a read. It
/// applies an action to every row the resolution returned, and `purge` and
/// `transition` are two of the six actions.
@Suite("Local bulk actions honor the narrowing they were given", .timeLimit(.minutes(1)))
struct BulkActionLocalFilterTests {

    /// A synced-mode client over an in-memory store, so the queue exists and
    /// the encoder path the confirmation used to hide in is reachable.
    private func makeSyncedClient() async throws -> MarfaClient {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let (store, queue, container) = try await MarfaSDKTest.makeInMemoryStorePair()
        return MarfaClient(
            configuration: config,
            transport: mock,
            localStore: store,
            mutationQueue: queue,
            syncEngine: SyncEngine(
                transport: mock,
                localStore: store,
                mutationQueue: queue,
                connectionManager: ConnectionStateManager()
            ),
            container: container
        )
    }

    /// Two rows under one source, for the cases where the source axis is not
    /// what is being tested.
    private func seedTwoNotes(_ client: MarfaClient) async throws {
        for body in ["first", "second"] {
            _ = try await client.items.create(
                CreateItemInput(type: "core.note", properties: ["body": .string(body)], source: "seed")
            )
        }
    }

    // MARK: - The narrowing

    /// The expression grammar is the server's and is not implemented locally,
    /// so the action is refused rather than resolved without it.
    @Test("an expression filter is refused, not dropped")
    func expressionFilterIsRefused() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        try await seedTwoNotes(client)

        do {
            _ = try await client.items.bulkAction(
                .transition(
                    filter: BulkActionFilter(filter: #"body eq "no-such-value""#),
                    state: .archived
                )
            )
            Issue.record("expected LocalFilterUnsupportedError")
        } catch let error as LocalFilterUnsupportedError {
            #expect(error.operation == "items.bulkAction")
            #expect(error.field == "filter")
            // A refusal that reports itself as retryable invites a caller loop.
            #expect(error.isPermanent)
        }
    }

    /// The refusal has to be inert. A throw *after* the fan-out would be worse
    /// than the defect it replaces, so this asserts the error and the store.
    @Test("a refused purge throws before it touches anything")
    func refusedPurgeChangesNothing() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        try await seedTwoNotes(client)

        await #expect(throws: LocalFilterUnsupportedError.self) {
            _ = try await client.items.bulkAction(
                .purge(
                    filter: BulkActionFilter(filter: #"body eq "no-such-value""#),
                    options: BulkActionOptions(confirm: "PURGE")
                )
            )
        }

        let remaining = try await client.items.list(filters: ListFilters(state: .active))
        #expect(remaining.data.count == 2)
    }

    /// `source` is a plain stored column, so it narrows rather than being
    /// refused. A mixed population is what makes this a test of *selection*
    /// rather than of all-or-nothing: a clause that was deleted matches both
    /// rows, and one that matches nothing matches neither.
    @Test("a source narrowing selects, rather than matching all or none")
    func sourceSelects() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let kept = try await client.items.create(
            CreateItemInput(type: "core.note", properties: ["body": .string("a")], source: "source-a")
        )
        _ = try await client.items.create(
            CreateItemInput(type: "core.note", properties: ["body": .string("b")], source: "source-b")
        )

        let result = try await client.items.bulkAction(
            .transition(filter: BulkActionFilter(source: "source-a"), state: .archived)
        )

        #expect(result.matched == 1)
        let archived = try await client.items.list(filters: ListFilters(state: .archived))
        #expect(archived.data.map(\.id) == [kept.id])
    }

    // MARK: - The refusals that used to happen after the fan-out

    /// The purge confirmation lived only in the encoder, which runs when the
    /// mutation is queued — after the rows are already gone, and never at all
    /// on a client with no queue.
    @Test("a purge without its confirmation is refused before anything is purged")
    func purgeWithoutConfirmationIsRefused() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        try await seedTwoNotes(client)

        await #expect(throws: BulkConfirmationRequiredError.self) {
            _ = try await client.items.bulkAction(
                .purge(filter: BulkActionFilter(type: "core.note"), options: BulkActionOptions())
            )
        }

        let remaining = try await client.items.list(filters: ListFilters(state: .active))
        #expect(remaining.data.count == 2, "rows were purged by a call that had no confirmation")
    }

    /// `maxItems` caps the match set *before* an error on the server. Locally
    /// it used to become a fetch window, which turned a safety brake into a
    /// silent partial write.
    @Test("a match set above maxItems refuses the action rather than trimming it")
    func capRefusesRatherThanTrims() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        try await seedTwoNotes(client)

        do {
            _ = try await client.items.bulkAction(
                .purge(
                    filter: BulkActionFilter(type: "core.note"),
                    options: BulkActionOptions(confirm: "PURGE", maxItems: 1)
                )
            )
            Issue.record("expected BulkCapExceededError")
        } catch let error as BulkCapExceededError {
            #expect(error.matched == 2)
            #expect(error.cap == 1)
        }

        let remaining = try await client.items.list(filters: ListFilters(state: .active))
        #expect(remaining.data.count == 2, "a capped purge trimmed instead of refusing")
    }

    /// The cap guards all six actions, not just the destructive one. Without
    /// this, scoping the check to `purge` leaves every other test green while
    /// a capped `transition` archives everything it matched — the same brake
    /// that does not brake, one action along.
    @Test("the cap refuses a non-purge action too")
    func capRefusesOnNonPurgeAction() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        try await seedTwoNotes(client)

        await #expect(throws: BulkCapExceededError.self) {
            _ = try await client.items.bulkAction(
                .transition(
                    filter: BulkActionFilter(type: "core.note"),
                    state: .archived,
                    options: BulkActionOptions(maxItems: 1)
                )
            )
        }

        let stillActive = try await client.items.list(filters: ListFilters(state: .active))
        #expect(stillActive.data.count == 2, "a capped transition ran anyway")
    }

    /// A cap the match set fits inside is not an error, which is the
    /// discriminator: without this, refusing every capped call would pass.
    @Test("a match set within maxItems proceeds")
    func capWithinBoundsProceeds() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        try await seedTwoNotes(client)

        let result = try await client.items.bulkAction(
            .transition(
                filter: BulkActionFilter(type: "core.note"),
                state: .archived,
                options: BulkActionOptions(maxItems: 2)
            )
        )

        #expect(result.matched == 2)
    }

    /// The cap a caller sets is only half of it: the server applies its own
    /// default when none is named, so an uncapped local resolution could act
    /// on far more than the server would then accept — and the replay's 400 is
    /// permanent, so the device acted, the server did not, and the write was
    /// dead-lettered. Pinning the numbers rather than the behavior because
    /// they are a mirror of another system's constants, and a mirror that
    /// drifts silently is the thing worth catching.
    @Test("the local cap mirrors the server's default and ceiling")
    func capMirrorsTheServer() {
        #expect(ItemsNamespace.defaultBulkActionCap == 10_000)
        #expect(ItemsNamespace.maxBulkActionCap == 50_000)
    }

    /// The original defect's worst form was synced: purge locally, throw at
    /// enqueue, queue nothing, so the caller saw an error over work that had
    /// already happened. Every other test here runs pure-local, where the
    /// encoder never ran at all — this is the half that reproduces the shape
    /// a person would have met.
    @Test("a synced client's purge without confirmation refuses before the fan-out")
    func syncedPurgeWithoutConfirmationIsRefused() async throws {
        let client = try await makeSyncedClient()
        _ = try await client.items.create(
            CreateItemInput(type: "core.note", properties: ["body": .string("kept")], source: "seed")
        )

        await #expect(throws: BulkConfirmationRequiredError.self) {
            _ = try await client.items.bulkAction(
                .purge(filter: BulkActionFilter(type: "core.note"), options: BulkActionOptions())
            )
        }

        let remaining = try await client.items.list(filters: ListFilters(state: .active))
        #expect(remaining.data.count == 1)
    }

    // MARK: - What this change deliberately leaves open

    /// The read path still drops `filter`, and that is a decision rather than
    /// an oversight — an over-wide read is corrected by the next read, where
    /// an over-wide action is not. Pinned so that closing it is a deliberate
    /// act rather than a surprise, per this repository's rule that an admitted
    /// limitation carries a test named for it.
    @Test("a local list still ignores the expression filter, deliberately")
    func localListStillIgnoresTheExpressionFilter() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        try await seedTwoNotes(client)

        var filters = ListFilters(type: "core.note")
        filters.filter = #"body eq "no-such-value""#
        let listed = try await client.items.list(filters: filters)

        #expect(listed.data.count == 2, "the read path narrowed on `filter`; the docblock says it does not")
    }

    /// `edge` and `backref` are structured fields on `ListFilters` that the
    /// local descriptor never reads. They cannot reach a bulk action — the
    /// bulk filter has no such fields, and the URL shorthand for them becomes
    /// part of the refused `filter` string — so these pin the read path only.
    ///
    /// One test per axis rather than one for both: setting them together
    /// covers the same mutations, but closing either axis alone produced a
    /// byte-identical failure, so the red could not say which had moved.
    @Test("a local list still ignores edge, deliberately")
    func localListStillIgnoresEdge() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        try await seedTwoNotes(client)

        var filters = ListFilters(type: "core.note")
        filters.edge = ["core.about": "no-such-target"]
        let listed = try await client.items.list(filters: filters)

        #expect(listed.data.count == 2, "the read path narrowed on `edge`; the docblock says it does not")
    }

    @Test("a local list still ignores backref, deliberately")
    func localListStillIgnoresBackref() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        try await seedTwoNotes(client)

        var filters = ListFilters(type: "core.note")
        filters.backref = ["core.reply": "no-such-source"]
        let listed = try await client.items.list(filters: filters)

        #expect(listed.data.count == 2, "the read path narrowed on `backref`; the docblock says it does not")
    }

    /// An empty expression is non-nil and so is refused. That is the safe
    /// direction — a caller joining conditional clauses into an empty string
    /// is told, rather than acting on everything — but it is behavior the
    /// prose would not lead you to expect, so it is pinned.
    @Test("an empty expression filter is refused like any other")
    func emptyExpressionFilterIsRefused() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        try await seedTwoNotes(client)

        await #expect(throws: LocalFilterUnsupportedError.self) {
            _ = try await client.items.bulkAction(
                .transition(filter: BulkActionFilter(filter: ""), state: .archived)
            )
        }
    }
}
