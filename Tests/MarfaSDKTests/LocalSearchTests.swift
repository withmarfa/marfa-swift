import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// Tests for ``LocalStore/searchItems(text:filters:)`` — the offline
/// search path — and the ``SearchQuery`` reactive wrapper over it.
///
/// All tests use an in-memory SwiftData container, so they leave no
/// on-disk artifacts and run safely in parallel.
// Every wait in this suite is a poll with no test-owned deadline, so this
// trait is what stops a starved condition hanging the run. It is coarse on
// purpose: a minute that names itself a timeout beats half a second that
// names the wrong thing.
@Suite("Local search", .timeLimit(.minutes(1)))
struct LocalSearchTests {

    // MARK: - Helpers

    private func makeStore() async throws -> LocalStore {
        try await MarfaSDKTest.makeInMemoryLocalStore()
    }

    /// Creates one item and returns its id. `title` / `body` are the only
    /// two properties search reads.
    ///
    /// Pass `id` when a test asserts on the `id` ascending tiebreak:
    /// generated ids are UUIDv7, so their lexical order tracks creation
    /// time and would agree with recency by construction, which is
    /// exactly what such a test needs to rule out.
    @discardableResult
    private func seed(
        _ store: LocalStore,
        title: String? = nil,
        body: String? = nil,
        type: String = "core.note",
        state: ItemState? = nil,
        tier: Tier? = nil,
        tags: [String] = [],
        id: String? = nil
    ) async throws -> String {
        var properties: [String: JSONValue] = [:]
        if let title { properties["title"] = .string(title) }
        if let body { properties["body"] = .string(body) }
        let item = try await store.createItem(
            CreateItemInput(type: type, properties: properties, id: id, state: state, tier: tier)
        )
        if !tags.isEmpty {
            try await store.addTags(itemId: item.id, tags: tags)
        }
        return item.id
    }

    // MARK: - Matching

    @Test("Matches text in the title") func matchesTitle() async throws {
        let store = try await makeStore()
        let id = try await seed(store, title: "Quarterly invoice", body: "unrelated")
        try await seed(store, title: "Shopping list", body: "milk")

        let results = try await store.searchItems(text: "invoice")

        #expect(results.count == 1)
        #expect(results[0].item.id == id)
    }

    @Test("Matches text in the body") func matchesBody() async throws {
        let store = try await makeStore()
        let id = try await seed(store, title: "Notes", body: "remember to file the invoice")

        let results = try await store.searchItems(text: "invoice")

        #expect(results.count == 1)
        #expect(results[0].item.id == id)
    }

    @Test("Matching ignores case and diacritics") func matchesCaseAndDiacriticInsensitively() async throws {
        let store = try await makeStore()
        try await seed(store, title: "Café Résumé")

        #expect(try await store.searchItems(text: "cafe").count == 1)
        #expect(try await store.searchItems(text: "RESUME").count == 1)
    }

    @Test("Properties other than title and body are not searched") func ignoresOtherProperties() async throws {
        let store = try await makeStore()
        _ = try await store.createItem(
            CreateItemInput(
                type: "core.note",
                properties: ["description": .string("invoice"), "title": .string("Untitled")]
            )
        )

        // A documented divergence from the server, which also indexes
        // `description`. Pinned so the gap is a decision, not a surprise.
        #expect(try await store.searchItems(text: "invoice").isEmpty)
    }

    @Test("Results carry the item's metadata and no snippet") func resultShape() async throws {
        let store = try await makeStore()
        try await seed(store, title: "Tagged invoice", tags: ["finance"])

        let results = try await store.searchItems(text: "invoice")

        #expect(results.count == 1)
        #expect(results[0].metadata.tags == ["finance"])
        #expect(results[0].snippetHtml == nil)
        #expect(results[0].relevanceScore > 0)
    }

    // MARK: - Empty results

    @Test("No match returns an empty array") func noMatch() async throws {
        let store = try await makeStore()
        try await seed(store, title: "Shopping list", body: "milk")

        #expect(try await store.searchItems(text: "invoice").isEmpty)
    }

    @Test("Blank query returns nothing rather than everything") func blankQuery() async throws {
        let store = try await makeStore()
        try await seed(store, title: "Anything")

        #expect(try await store.searchItems(text: "").isEmpty)
        #expect(try await store.searchItems(text: "   \n ").isEmpty)
    }

    @Test("Empty store returns an empty array") func emptyStore() async throws {
        let store = try await makeStore()

        #expect(try await store.searchItems(text: "invoice").isEmpty)
    }

    // MARK: - Filtering

    @Test("Filters by type") func filtersByType() async throws {
        let store = try await makeStore()
        let noteId = try await seed(store, title: "Invoice note", type: "core.note")
        try await seed(store, title: "Invoice task", type: "core.task")

        let results = try await store.searchItems(
            text: "invoice",
            filters: SearchFilters(type: "core.note")
        )

        #expect(results.count == 1)
        #expect(results[0].item.id == noteId)
    }

    @Test("Filters by tier") func filtersByTier() async throws {
        let store = try await makeStore()
        let feedId = try await seed(store, title: "Invoice capture", tier: .feed)
        try await seed(store, title: "Invoice archive", tier: .library)

        let results = try await store.searchItems(
            text: "invoice",
            filters: SearchFilters(tier: .feed)
        )

        #expect(results.count == 1)
        #expect(results[0].item.id == feedId)
    }

    @Test("Trashed items are excluded unless the state filter asks for them") func trashedExcludedByDefault() async throws {
        let store = try await makeStore()
        let liveId = try await seed(store, title: "Live invoice")
        let deadId = try await seed(store, title: "Dead invoice")
        try await store.trashItem(id: deadId)

        let unfiltered = try await store.searchItems(text: "invoice")
        #expect(unfiltered.map(\.item.id) == [liveId])

        let trashed = try await store.searchItems(
            text: "invoice",
            filters: SearchFilters(state: .trashed)
        )
        #expect(trashed.map(\.item.id) == [deadId])
    }

    @Test("Tags filter requires every requested tag") func filtersByTagsAsAnd() async throws {
        let store = try await makeStore()
        let bothId = try await seed(store, title: "Invoice A", tags: ["finance", "urgent"])
        try await seed(store, title: "Invoice B", tags: ["finance"])
        try await seed(store, title: "Invoice C")

        let results = try await store.searchItems(
            text: "invoice",
            filters: SearchFilters(tags: ["finance", "urgent"])
        )

        #expect(results.map(\.item.id) == [bothId])
    }

    @Test("system.* items are excluded unless the type is named") func systemTypesExcluded() async throws {
        let store = try await makeStore()
        let deviceId = try await seed(store, title: "Invoice printer", type: "system.device")
        let noteId = try await seed(store, title: "Invoice note", type: "core.note")

        let unfiltered = try await store.searchItems(text: "invoice")
        #expect(unfiltered.map(\.item.id) == [noteId])

        let explicit = try await store.searchItems(
            text: "invoice",
            filters: SearchFilters(type: "system.device")
        )
        #expect(explicit.map(\.item.id) == [deviceId])
    }

    // MARK: - Ordering

    @Test("A title hit outranks a body hit") func titleOutranksBody() async throws {
        let store = try await makeStore()
        let bodyId = try await seed(store, title: "Something else", body: "invoice")
        let titleId = try await seed(store, title: "Invoice", body: "something else")

        let results = try await store.searchItems(text: "invoice")

        #expect(results.map(\.item.id) == [titleId, bodyId])
    }

    @Test("A tighter title hit outranks a looser one") func tighterHitOutranksLooser() async throws {
        let store = try await makeStore()
        // Seeded tightest-first, so the expected order is also the
        // *oldest*-first order. The descriptor sorts `updatedAt`
        // descending, so recency alone would produce exactly the reverse
        // of the assertion — it can only hold if the score is what
        // orders these rows.
        let wholeId = try await seed(store, title: "Invoice")
        let prefixId = try await seed(store, title: "Invoice folder")
        let substringId = try await seed(store, title: "The invoice folder")

        let results = try await store.searchItems(text: "invoice")

        #expect(results.map(\.item.id) == [wholeId, prefixId, substringId])
    }

    @Test("Equal scores break ties by updatedAt descending") func tiesBreakByRecency() async throws {
        let store = try await makeStore()
        // Ids are pinned, and ascending, so the `id` fallback would order
        // these [older, newer]. Bumping the *newer* row puts recency in
        // direct opposition to that, which is what makes the assertion
        // depend on the `updatedAt` comparator rather than the fallback
        // underneath it. Both titles are prefix matches, so relevance
        // cannot separate them either.
        let olderId = try await seed(store, title: "Invoice one", id: "aaaa-older")
        let newerId = try await seed(store, title: "Invoice two", id: "bbbb-newer")
        try await store.updateItem(id: newerId, properties: ["note": .string("touched")])

        let results = try await store.searchItems(text: "invoice")

        #expect(results.map(\.item.id) == [newerId, olderId])
    }

    @Test("Rows level on score and recency break ties by id ascending") func tiesBreakByIdWhenRecencyIsLevel() async throws {
        let store = try await makeStore()
        // `createItem` stamps `updatedAt` from the clock, so two rows
        // can only be made genuinely level by writing the timestamp
        // directly. Without that, the `id` comparator is unreachable:
        // every other fixture separates on score or recency first.
        let stamp = "2026-01-01T00:00:00.000Z"
        for id in ["item-b", "item-a", "item-c"] {
            try await store.upsertItem(
                Item(
                    captureLatitude: nil,
                    captureLongitude: nil,
                    createdAt: stamp,
                    device: nil,
                    edges: nil,
                    id: id,
                    properties: ["title": .string("Invoice")],
                    schemaVersion: 1,
                    source: "local",
                    sourceId: nil,
                    state: .active,
                    tier: .library,
                    timestamp: stamp,
                    type: "core.note",
                    updatedAt: stamp,
                    version: 1
                )
            )
        }

        let results = try await store.searchItems(text: "invoice")

        #expect(results.map(\.item.id) == ["item-a", "item-b", "item-c"])
    }

    @Test("Ordering is stable across repeated calls") func orderingIsStable() async throws {
        let store = try await makeStore()
        for index in 0..<10 {
            try await seed(store, title: "Invoice \(index)")
        }

        let first = try await store.searchItems(text: "invoice", filters: SearchFilters(limit: 10))
        let second = try await store.searchItems(text: "invoice", filters: SearchFilters(limit: 10))

        #expect(first.map(\.item.id) == second.map(\.item.id))
    }

    // MARK: - Limit

    @Test("Limit caps results after ranking") func limitCapsResults() async throws {
        let store = try await makeStore()
        for index in 0..<5 {
            try await seed(store, title: "Invoice \(index)")
        }

        let results = try await store.searchItems(
            text: "invoice",
            filters: SearchFilters(limit: 2)
        )

        #expect(results.count == 2)
    }

    @Test("Absent limit falls back to the server's default of 20") func defaultLimit() async throws {
        let store = try await makeStore()
        for index in 0..<25 {
            try await seed(store, title: "Invoice \(index)")
        }

        #expect(try await store.searchItems(text: "invoice").count == LocalStore.defaultSearchLimit)
        #expect(try await store.searchItems(text: "invoice", filters: SearchFilters(limit: 25)).count == 25)
    }

    @Test("Limit caps results without capping the fetch") func limitDoesNotCapTheFetch() async throws {
        let store = try await makeStore()
        // The best match is deliberately the *oldest* row. The descriptor
        // sorts `updatedAt` descending and carries no `fetchLimit`, so
        // this row is still read and ranked. Sizing a `fetchLimit` to the
        // result limit — the obvious-looking optimization the descriptor
        // documents itself as refusing — would drop it before it was ever
        // scored, and the top hit would silently become a weaker one.
        let wholeId = try await seed(store, title: "Invoice")
        for index in 0..<5 {
            try await seed(store, title: "Invoice folder \(index)")
        }

        let results = try await store.searchItems(
            text: "invoice",
            filters: SearchFilters(limit: 3)
        )

        #expect(results.count == 3)
        #expect(results.first?.item.id == wholeId)
    }

    @Test("A limit of zero or less returns nothing") func nonPositiveLimitReturnsNothing() async throws {
        let store = try await makeStore()
        try await seed(store, title: "Invoice")

        // The server rejects these outright (`limit` is 1...100). Locally
        // they resolve to an empty result rather than an error — see the
        // divergence note on `searchItems`.
        #expect(try await store.searchItems(text: "invoice", filters: SearchFilters(limit: 0)).isEmpty)
        #expect(try await store.searchItems(text: "invoice", filters: SearchFilters(limit: -5)).isEmpty)
    }

    // MARK: - Cancellation

    @Test("A cancelled search abandons the scan instead of finishing it") func cancelledSearchThrows() async throws {
        let store = try await makeStore()
        for index in 0..<200 {
            try await seed(store, title: "Invoice \(index)")
        }

        let task = Task { () -> [SearchResult] in
            // `cancel()` below lands while this sleep is pending, so the
            // sleep throws and the search runs inside an already-cancelled
            // task — the state the scan's checks exist to catch. Without
            // them the scan would run to completion and return results
            // nobody is waiting for, holding the store actor throughout.
            try? await Task.sleep(for: .milliseconds(50))
            return try await store.searchItems(text: "invoice")
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    // MARK: - Main-actor behavior

    @Test("Searching does not block the main actor")
    @MainActor
    func searchDoesNotBlockMainActor() async throws {
        let store = try await makeStore()
        // Enough rows that the scan is real work rather than a no-op.
        for index in 0..<50 {
            try await seed(store, body: "filler \(index)")
        }
        try await seed(store, title: "Invoice")

        // One job enqueued on the main actor *before* the search starts.
        // The main actor runs its queue in order, so this job goes ahead of
        // the search's resumption — but only if the search suspends the
        // main actor at all. A scan run inline on the main actor would
        // finish first and leave the probe at zero, which is exactly what
        // this pins.
        let probe = MainActorProbe()
        Task { @MainActor in probe.ran += 1 }

        let results = try await store.searchItems(text: "invoice")

        #expect(results.count == 1)
        #expect(probe.ran == 1)
    }

    // MARK: - Client integration

    @Test("A pure-local client serves search from the store") func localClientSearch() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        _ = try await client.items.create(
            CreateItemInput(
                type: "core.note",
                // The body deliberately does NOT contain the needle. This is
                // the only test that proves search reaches `title` at all, and
                // a body echoing the search term would let it pass against a
                // build where title matching is gone entirely.
                properties: ["title": .string("Local invoice"), "body": .string("filed last week")]
            )
        )

        let results = try await client.search(query: "invoice")

        #expect(results.count == 1)
        #expect(results[0].item.properties["title"] == .string("Local invoice"))
    }
}

/// Records whether a job enqueued on the main actor got to run. A class so
/// the job and the assertion share one instance; `@MainActor` so the
/// mutation needs no locking under strict concurrency.
@MainActor
private final class MainActorProbe {
    var ran = 0
}

// MARK: - Reactive wrapper

/// Tests for ``SearchQuery``. Bodies are `@MainActor`-isolated because
/// the query is `@Observable @MainActor`, matching ``MarfaStoreTests``.
// Every wait in this suite is a poll with no test-owned deadline, so this
// trait is what stops a starved condition hanging the run. It is coarse on
// purpose: a minute that names itself a timeout beats half a second that
// names the wrong thing.
@Suite("SearchQuery", .timeLimit(.minutes(1)))
@MainActor
struct SearchQueryTests {

    private func makeStore() async throws -> (MarfaClient, MarfaStore) {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        return (client, try #require(client.makeStore()))
    }

    private func note(_ title: String) -> CreateItemInput {
        // `core.note` requires a body, and the store enforces that now — these
        // fixtures used to build items the server would have refused.
        //
        // The body is fixed text rather than anything derived from `title`,
        // and that is not tidiness. Every caller searches for a word from the
        // title, so a body interpolating the title would match the needle too
        // and no test here could tell title matching from body matching.
        CreateItemInput(
            type: "core.note",
            properties: ["title": .string(title), "body": .string("filed for review")]
        )
    }

    @Test("Delivers matching results") func deliversResults() async throws {
        let (client, store) = try await makeStore()
        _ = try await client.items.create(note("Quarterly invoice"))
        _ = try await client.items.create(note("Shopping list"))

        let query = store.querySearch(text: "invoice")
        try await awaitCondition(description: "query.isLoading == false") { query.isLoading == false }

        #expect(query.results.count == 1)
        #expect(query.error == nil)
        query.stop()
    }

    @Test("Does not scan inline on the main actor") func doesNotScanInInit() async throws {
        let (client, store) = try await makeStore()
        _ = try await client.items.create(note("Quarterly invoice"))

        let query = store.querySearch(text: "invoice")
        // Construction hands the scan to the LocalStore actor, so nothing
        // has landed yet at this point — a scan run inline in `init` would
        // already have cleared `isLoading`.
        #expect(query.isLoading == true)
        #expect(query.results.isEmpty)

        try await awaitCondition(description: "query.isLoading == false") { query.isLoading == false }
        #expect(query.results.count == 1)
        query.stop()
    }

    @Test("Picks up items created after the query started") func updatesOnWrite() async throws {
        let (client, store) = try await makeStore()
        let query = store.querySearch(text: "invoice")
        try await awaitCondition(description: "query.isLoading == false") { query.isLoading == false }
        #expect(query.results.isEmpty)

        _ = try await client.items.create(note("A new invoice"))
        try await awaitCondition(description: "query.results.count == 1") { query.results.count == 1 }

        query.stop()
    }

    @Test("Honors the filter surface") func honorsFilters() async throws {
        let (client, store) = try await makeStore()
        _ = try await client.items.create(note("Invoice note"))
        _ = try await client.items.create(
            CreateItemInput(type: "core.task", properties: ["title": .string("Invoice task")])
        )

        let query = store.querySearch(text: "invoice", filters: SearchFilters(type: "core.task"))
        try await awaitCondition(description: "query.isLoading == false") { query.isLoading == false }

        #expect(query.results.count == 1)
        #expect(query.results[0].item.type == "core.task")
        query.stop()
    }

    @Test("stop() halts further updates") func stopHaltsUpdates() async throws {
        let (client, store) = try await makeStore()
        let query = store.querySearch(text: "invoice")
        try await awaitCondition(description: "query.isLoading == false") { query.isLoading == false }
        query.stop()

        _ = try await client.items.create(note("Late invoice"))

        // A negative needs a window, so this one keeps a duration where the
        // rest of the suite dropped theirs — and the duration is derived from
        // the thing it is about. `RefreshDebounce.interval` is the coalescing
        // window between `didSave` and a refetch, so a refresh that was going
        // to happen has had eight of them to happen in.
        try await expectRemains(
            for: .milliseconds(RefreshDebounce.interval * 8),
            description: "a stopped search query stays empty"
        ) {
            query.results.isEmpty
        }
    }
}
