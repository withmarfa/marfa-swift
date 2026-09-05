import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// Tests for ``LocalStore`` CRUD and ``MarfaClient/local(path:)`` pure-local mode.
///
/// All tests use an in-memory SwiftData container so they leave no on-disk
/// artifacts and run safely in parallel.
@Suite("LocalStore", .timeLimit(.minutes(1)))
struct LocalStoreTests {

    // MARK: - Helpers

    private func makeStore() async throws -> LocalStore {
        try await MarfaSDKTest.makeInMemoryLocalStore()
    }

    private func makeLocalClient() async throws -> MarfaClient {
        try await MarfaClient.local(path: ":memory:")
    }

    private func noteInput(body: String = "Hello", title: String? = nil) -> CreateItemInput {
        var props: [String: JSONValue] = ["body": .string(body)]
        if let title { props["title"] = .string(title) }
        return CreateItemInput(type: "core.note", properties: props)
    }

    // MARK: - Schema / lifecycle

    @Test("In-memory store opens without error") func openStore() async throws {
        _ = try await makeStore()
    }

    @Test("MarfaClient.local(path:) creates a working client") func localClient() async throws {
        _ = try await makeLocalClient()
    }

    @Test("MarfaClient.local(container:) creates a working client from a caller-built container") func localClientFromContainer() async throws {
        let container = try MarfaModelContainer.make(path: ":memory:")
        let client = try await MarfaClient.local(container: container)
        let item = try await client.items.create(noteInput(body: "hello"))
        #expect(item.properties["body"] == .string("hello"))
        // Round-trip: fetch through a second client on the same container
        // to prove the SDK honors the injected store (not a fresh one).
        let second = try await MarfaClient.local(container: container)
        let fetched = try await second.items.get(id: item.id)
        #expect(fetched.id == item.id)
    }

    @Test("MarfaModelContainer.make(path:cloudKitDatabase:) defaults to .none") func containerDefaultsToNoneCloudKit() throws {
        // Smoke-level: the in-memory branch forces `.none` regardless,
        // but exercising the default-argument path guards against
        // accidental signature regressions.
        _ = try MarfaModelContainer.make(path: ":memory:")
    }

    @Test("SDK container construction serializes behind the shared creation lock")
    func containerConstructionSerializes() async throws {
        // Overlapping `make(path:)` calls do not fail on their own — SwiftData
        // container construction is racy, not crash-on-contention — so a test
        // that only fans out and expects no throw passes with or without the
        // lock. Holding the lock and proving a concurrent `make` cannot get
        // past it is what actually pins the serialization down.

        // Pay SwiftData's one-time setup cost first so the observation window
        // measures the lock, not container construction.
        _ = try MarfaModelContainer.make(path: ":memory:")

        let releaseLock = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (acquired: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                MarfaModelContainer.withCreationLock {
                    acquired.resume()
                    releaseLock.wait()
                }
            }
        }

        let completed = TestLatch()
        DispatchQueue.global().async {
            _ = try? MarfaModelContainer.make(path: ":memory:")
            Task { await completed.set() }
        }

        try await SyncEngineTestKit.expectRemainsFalse(for: .milliseconds(400)) {
            await completed.isSet
        }

        releaseLock.signal()
        try await SyncEngineTestKit.awaitCondition(description: "completed.isSet") {
            await completed.isSet
        }
    }

    // MARK: - Item CRUD (via LocalStore directly)

    @Test("createItem generates an ID and stores the item") func createItem() async throws {
        let store = try await makeStore()
        let input = noteInput(body: "My note")
        let item = try await store.createItem(input)

        #expect(!item.id.isEmpty)
        #expect(item.type == "core.note")
        #expect(item.properties["body"] == .string("My note"))
        #expect(item.state == .active)
        #expect(item.version == 1)
    }

    @Test("fetchItem returns stored item") func fetchItem() async throws {
        let store = try await makeStore()
        let created = try await store.createItem(noteInput())
        let fetched = try await store.fetchItem(id: created.id)
        #expect(fetched.id == created.id)
        #expect(fetched.properties["body"] == created.properties["body"])
    }

    @Test("fetchItem throws NotFoundError for unknown ID") func fetchItemMissing() async throws {
        let store = try await makeStore()
        do {
            _ = try await store.fetchItem(id: "no-such-id")
            Issue.record("Expected NotFoundError")
        } catch let e as NotFoundError {
            #expect(e.status == 404)
        }
    }

    @Test("fetchItems returns all created items") func fetchItems() async throws {
        let store = try await makeStore()
        let a = try await store.createItem(noteInput(body: "A"))
        let b = try await store.createItem(noteInput(body: "B"))
        let result = try await store.fetchItems(filters: nil)
        let ids = result.data.map(\.id)
        #expect(ids.contains(a.id))
        #expect(ids.contains(b.id))
        // No limit, so nothing was left behind. `hasMore` used to read
        // `false` here whether or not that was true; the pagination suite
        // below is what pins the difference.
        #expect(result.hasMore == false)
        #expect(result.cursor == nil)
    }

    // MARK: - system.* rows

    // The store holds `system.*` rows — the stream writes them and, since the
    // import began asking for them, so does that. What a *listing* does with
    // them is a separate question, and the answer has to match the server's:
    // it drops them from a list and from search, and from nowhere else. The
    // pair below is the same pair `LocalSearchTests` pins for search, because
    // either half alone is satisfied by a broken implementation.

    @Test("an untyped list leaves system.* rows out")
    func untypedListExcludesSystemRows() async throws {
        let store = try await makeStore()
        let note = try await store.createItem(noteInput(body: "a note someone wrote"))
        _ = try await store.createItem(
            CreateItemInput(type: "system.activity", properties: ["body": .string("a sync happened")])
        )
        _ = try await store.createItem(
            CreateItemInput(type: "system.connection", properties: ["body": .string("an integration")])
        )

        let ids = try await store.fetchItems(filters: nil).data.map(\.id)

        // Not `!ids.contains(...)`: the point is that the list holds the one
        // row a person filed and nothing else, and a count assertion is what
        // fails when a third system type is added later.
        #expect(ids == [note.id])
    }

    @Test("a list naming a system type returns those rows")
    func typedListReturnsSystemRows() async throws {
        // The other half, and the one that matters most. `connections.list()`
        // is `items.list(type: "system.connection")`, so an exclusion that
        // did not make room for a caller naming the type outright would empty
        // the one API whose whole purpose is reading these rows — the leak
        // above, inverted, and no better.
        let store = try await makeStore()
        _ = try await store.createItem(noteInput(body: "a note someone wrote"))
        let connection = try await store.createItem(
            CreateItemInput(type: "system.connection", properties: ["body": .string("an integration")])
        )

        let ids = try await store.fetchItems(
            filters: ListFilters(type: "system.connection")
        ).data.map(\.id)

        #expect(ids == [connection.id])
    }

    @Test("stats still counts system rows, because the server does")
    func statsCountsSystemRows() async throws {
        // Deliberately not excluded, and worth pinning so nobody "fixes" it
        // into agreement with the list above. The server applies its
        // `system.%` exclusion in exactly two places, the item listing and
        // search; `stats()` counts every row. Adding the clause here would
        // create a local/remote divergence rather than close one.
        let store = try await makeStore()
        _ = try await store.createItem(noteInput(body: "a note someone wrote"))
        _ = try await store.createItem(
            CreateItemInput(type: "system.activity", properties: ["body": .string("a sync happened")])
        )

        #expect(try await store.itemStats()["active"] == 2)
    }

    // MARK: - Pagination
    //
    // A limit used to be applied and then reported as `hasMore: false`, so a
    // caller looping until `!hasMore` stopped after one page and believed it
    // had everything. These pin both halves: that truncation is announced,
    // and that the cursor actually reaches the rest.

    /// Seeds `count` items and returns their ids in the order `fetchItems`
    /// will hand them back with no filters.
    private func seedOrderedItems(_ store: LocalStore, count: Int) async throws -> [String] {
        for i in 0..<count {
            _ = try await store.createItem(noteInput(body: "item \(i)"))
        }
        return try await store.fetchItems(filters: nil).data.map(\.id)
    }

    @Test("a limit that truncates says so and offers a cursor")
    func fetchItemsAnnouncesTruncation() async throws {
        let store = try await makeStore()
        _ = try await seedOrderedItems(store, count: 5)

        let page = try await store.fetchItems(filters: ListFilters(limit: 2))
        #expect(page.data.count == 2)
        #expect(page.hasMore == true)
        #expect(page.cursor != nil)
    }

    @Test("a limit that does not truncate reports no more")
    func fetchItemsExactFitReportsNoMore() async throws {
        let store = try await makeStore()
        _ = try await seedOrderedItems(store, count: 3)

        // Exactly the number of rows there are: the probe fetches one past
        // the limit and finds nothing, so this is the boundary that a
        // count-based check would get wrong.
        let page = try await store.fetchItems(filters: ListFilters(limit: 3))
        #expect(page.data.count == 3)
        #expect(page.hasMore == false)
        #expect(page.cursor == nil)
    }

    @Test("paging a local store reaches every row exactly once")
    func fetchItemsPagesThroughEverything() async throws {
        let store = try await makeStore()
        let expected = try await seedOrderedItems(store, count: 7)

        var collected: [String] = []
        var cursor: String? = nil
        var pages = 0
        repeat {
            var filters = ListFilters(limit: 2)
            filters.cursor = cursor
            let page = try await store.fetchItems(filters: filters)
            collected.append(contentsOf: page.data.map(\.id))
            cursor = page.cursor
            pages += 1
            #expect(pages < 10, "paging did not terminate")
            if !page.hasMore { break }
        } while cursor != nil

        #expect(collected == expected)
        #expect(Set(collected).count == collected.count, "a row was returned twice")
    }

    @Test("paging edges reaches every edge exactly once")
    func fetchEdgesPagesThroughEverything() async throws {
        let store = try await makeStore()
        let a = try await store.createItem(noteInput(body: "source"))
        var expected: [String] = []
        for i in 0..<5 {
            let target = try await store.createItem(noteInput(body: "target \(i)"))
            let edge = try await store.createEdge(
                source: a.id, target: target.id,
                edgeType: "about", properties: nil
            )
            expected.append(edge.id)
        }

        var collected: [String] = []
        var cursor: String? = nil
        repeat {
            let page = try await store.fetchEdgesFromSource(
                sourceId: a.id, edgeType: nil, cursor: cursor, limit: 2
            )
            collected.append(contentsOf: page.data.map(\.id))
            cursor = page.cursor
            if !page.hasMore { break }
        } while cursor != nil

        #expect(Set(collected) == Set(expected))
        #expect(Set(collected).count == collected.count, "an edge was returned twice")
    }

    // MARK: - Date range
    //
    // `since`/`until` used to compare `updatedAt` here while the server
    // compares `COALESCE(timestamp, created_at)` and every card in a consumer
    // app drew `timestamp`. Choosing "today" returned items *edited* today on
    // rows dated months earlier, and the same filter through search returned
    // a different set again.

    @Test("a date range filters on the item's own timestamp, not when it was last edited")
    func fetchItemsDateRangeUsesTimestamp() async throws {
        let store = try await makeStore()
        var input = noteInput(body: "dated last year")
        input.timestamp = "2025-03-01T12:00:00.000Z"
        let item = try await store.createItem(input)

        // Editing it now moves `updatedAt` to today and leaves `timestamp`
        // where it was. This is the divergence, made deliberate.
        _ = try await store.updateItem(id: item.id, properties: ["body": .string("edited today")])

        let aroundItsOwnDate = try await store.fetchItems(
            filters: ListFilters(timestampAfter: "2025-02-01T00:00:00.000Z", timestampBefore: "2025-04-01T00:00:00.000Z")
        )
        #expect(aroundItsOwnDate.data.map(\.id).contains(item.id))

        let aroundTheEdit = try await store.fetchItems(
            filters: ListFilters(timestampAfter: "2026-01-01T00:00:00.000Z")
        )
        #expect(!aroundTheEdit.data.map(\.id).contains(item.id),
                "an item edited today is not an item dated today")
    }

    @Test("an item with no timestamp is judged on when it was created")
    func dateBoundsFallBackToCreatedAt() async throws {
        // Exercised directly: the store always stamps a timestamp on create,
        // so a row without one only arrives by syncing from a server where
        // the column is nullable, which is the case the server's COALESCE
        // exists for.
        let undated = MarfaItemModel()
        undated.id = "undated"
        undated.timestamp = ""
        undated.createdAt = "2025-06-15T00:00:00.000Z"

        let inRange = LocalStore.applyDateBounds(
            [undated],
            filters: ListFilters(timestampAfter: "2025-06-01T00:00:00.000Z", timestampBefore: "2025-07-01T00:00:00.000Z")
        )
        #expect(inRange.count == 1)

        let outOfRange = LocalStore.applyDateBounds(
            [undated],
            filters: ListFilters(timestampAfter: "2025-08-01T00:00:00.000Z")
        )
        #expect(outOfRange.isEmpty, "an undated item is not silently kept, nor silently dropped")

        // The mirror case, and it was missing everywhere. Every date exclusion
        // in this suite narrowed with a *lower* bound, so deleting the upper
        // bound's branch from `applyDateBounds` left the whole suite green.
        let afterTheWindow = LocalStore.applyDateBounds(
            [undated],
            filters: ListFilters(timestampBefore: "2025-06-01T00:00:00.000Z")
        )
        #expect(afterTheWindow.isEmpty, "an upper bound did not exclude a later item")
    }

    // MARK: - Tag and tier filters
    //
    // Both used to be accepted and dropped, so a filtered list returned
    // everything. Tags cannot narrow a fetch (they live in an opaque blob on
    // a separate row), so they are applied after a metadata join, which is
    // why the paging case below is worth its own test.

    @Test("tier narrows a local list")
    func fetchItemsFiltersByTier() async throws {
        let store = try await makeStore()
        let library = try await store.createItem(noteInput(body: "library"))
        let feed = try await store.createItem(noteInput(body: "feed"))
        _ = try await store.updateItem(id: feed.id, properties: [:], tier: .feed)

        let feedOnly = try await store.fetchItems(filters: ListFilters(tier: .feed))
        #expect(feedOnly.data.map(\.id) == [feed.id])
        #expect(!feedOnly.data.map(\.id).contains(library.id))
    }

    @Test("tags narrow a local list, and every requested tag must be present")
    func fetchItemsFiltersByTags() async throws {
        let store = try await makeStore()
        let both = try await store.createItem(noteInput(body: "both"))
        let one = try await store.createItem(noteInput(body: "one"))
        let none = try await store.createItem(noteInput(body: "none"))
        try await store.setMetadata(itemId: both.id, input: MetadataInput(tags: ["red", "blue"]))
        try await store.setMetadata(itemId: one.id, input: MetadataInput(tags: ["red"]))

        let red = try await store.fetchItems(filters: ListFilters(tags: ["red"]))
        #expect(Set(red.data.map(\.id)) == [both.id, one.id])
        #expect(!red.data.map(\.id).contains(none.id))

        // AND, not OR: the server requires every listed tag.
        let redAndBlue = try await store.fetchItems(filters: ListFilters(tags: ["red", "blue"]))
        #expect(redAndBlue.data.map(\.id) == [both.id])
    }

    @Test("a tag-filtered list pages over the filtered set, not the raw one")
    func fetchItemsPagesTagFiltered() async throws {
        let store = try await makeStore()
        var tagged: Set<String> = []
        // Interleaved so a page taken before filtering would be mostly
        // untagged rows, which is the shape that produced short pages.
        for i in 0..<10 {
            let item = try await store.createItem(noteInput(body: "n\(i)"))
            if i % 2 == 0 {
                try await store.setMetadata(itemId: item.id, input: MetadataInput(tags: ["keep"]))
                tagged.insert(item.id)
            }
        }

        var collected: [String] = []
        var cursor: String? = nil
        var pages = 0
        repeat {
            var filters = ListFilters(tags: ["keep"], limit: 2)
            filters.cursor = cursor
            let page = try await store.fetchItems(filters: filters)
            #expect(page.data.allSatisfy { tagged.contains($0.id) })
            collected.append(contentsOf: page.data.map(\.id))
            cursor = page.cursor
            pages += 1
            #expect(pages < 10, "paging did not terminate")
            if !page.hasMore { break }
        } while cursor != nil

        #expect(Set(collected) == tagged)
        #expect(Set(collected).count == collected.count, "a row was returned twice")
    }

    @Test("a reactive item query narrows on tags too")
    func itemQueryFiltersByTags() async throws {
        let client = try await makeLocalClient()
        let kept = try await client.items.create(
            CreateItemInput(type: "core.note", properties: ["body": .string("kept")])
        )
        _ = try await client.items.create(
            CreateItemInput(type: "core.note", properties: ["body": .string("dropped")])
        )
        try await client.metadata.set(itemId: kept.id, input: MetadataInput(tags: ["keep"]))

        let store = try #require(await client.makeStore())
        let query = await store.query(filters: ListFilters(tags: ["keep"]))
        // Wait on readiness, then assert — not on the assertion itself. The
        // two look interchangeable and are not: a poll on `ids == [kept.id]`
        // reports a *wrong* answer as a timeout naming the wait, where this
        // reports it as the diff naming the rows. The sibling reactive-query
        // suite states the same rule at its own call sites.
        try await awaitCondition(description: "the tag-filtered query to finish loading") {
            await query.isLoading == false
        }
        let ids = await query.items.map { $0.id }
        #expect(ids == [kept.id])
    }

    @Test("a cursor that is not ours is refused rather than restarting")
    func fetchItemsRejectsForeignCursor() async throws {
        let store = try await makeStore()
        _ = try await seedOrderedItems(store, count: 3)

        var filters = ListFilters(limit: 2)
        // The shape the server mints. Silently treating it as "no cursor"
        // would return page one forever.
        filters.cursor = "eyJ2IjoiMjAyNi0wOC0yNSIsImlkIjoiYWJjIn0"
        await #expect(throws: ValidationError.self) {
            _ = try await store.fetchItems(filters: filters)
        }
    }

    @Test("listWithMetadata keeps the order it was asked for and paginates")
    func listWithMetadataOrdersAndPaginates() async throws {
        let client = try await makeLocalClient()
        for i in 0..<6 {
            _ = try await client.items.create(
                CreateItemInput(type: "core.note", properties: ["body": .string("n\(i)")])
            )
        }
        let plain = try await client.items.list(filters: ListFilters(limit: 4))
        let withMeta = try await client.items.listWithMetadata(filters: ListFilters(limit: 4))

        // The metadata join used to collect from a task group in completion
        // order, so the page came back shuffled and its cursor discarded.
        #expect(withMeta.data.map(\.item.id) == plain.data.map(\.id))
        #expect(withMeta.hasMore == plain.hasMore)
        #expect((withMeta.cursor == nil) == (plain.cursor == nil))
    }

    @Test("fetchItems filters by type") func fetchItemsFiltersByType() async throws {
        let store = try await makeStore()
        _ = try await store.createItem(noteInput())
        _ = try await store.createItem(CreateItemInput(type: "core.task", properties: ["title": "Task"]))
        let notes = try await store.fetchItems(filters: ListFilters(type: "core.note"))
        #expect(notes.data.allSatisfy { $0.type == "core.note" })
        #expect(notes.data.count == 1)
    }

    @Test("fetchItems filters by state") func fetchItemsFiltersByState() async throws {
        let store = try await makeStore()
        let active = try await store.createItem(noteInput(body: "keep"))
        let toTrash = try await store.createItem(noteInput(body: "trash me"))
        try await store.trashItem(id: toTrash.id)
        let actives = try await store.fetchItems(filters: ListFilters(state: .active))
        #expect(actives.data.map(\.id).contains(active.id))
        #expect(!actives.data.map(\.id).contains(toTrash.id))
    }

    @Test("updateItem merges properties and increments version") func updateItemMergesPropertiesAndIncrementsVersion() async throws {
        let store = try await makeStore()
        let item = try await store.createItem(
            noteInput(body: "original", title: "Original title")
        )
        // Delta only carries `body`. Server-PATCH parity means `title` survives.
        let updated = try await store.updateItem(
            id: item.id,
            properties: ["body": .string("revised")]
        )
        #expect(updated.version == 2)
        #expect(updated.properties["body"] == .string("revised"))
        #expect(updated.properties["title"] == .string("Original title"))
    }

    @Test("updateItem with no tier override preserves existing flag") func updateItemPreservesTierWhenAbsent() async throws {
        let store = try await makeStore()
        let input = CreateItemInput(
            type: "core.note",
            properties: ["body": .string("x")],
            tier: .library
        )
        let item = try await store.createItem(input)
        #expect(item.tier == .library)
        let updated = try await store.updateItem(
            id: item.id,
            properties: ["body": .string("y")]
        )
        #expect(updated.tier == .library)
    }

    @Test("updateItem with tier override applies the new value") func updateItemAppliesTierOverride() async throws {
        let store = try await makeStore()
        let input = CreateItemInput(
            type: "core.note",
            properties: ["body": .string("x")],
            tier: .feed
        )
        let item = try await store.createItem(input)
        #expect(item.tier == .feed)
        let updated = try await store.updateItem(
            id: item.id,
            properties: [:],
            tier: .library
        )
        #expect(updated.tier == .library)
    }

    @Test("newId generates UUIDv7 (timestamp-prefixed)") func newIdGeneratesUUIDv7() throws {
        // RFC 9562: byte 6 high nibble is the version (= 7).
        // String position 14 (0-indexed) sits within the third hex group.
        let id = UUIDv7.generateString()
        let chars = Array(id)
        // Format: xxxxxxxx-xxxx-7xxx-yxxx-xxxxxxxxxxxx
        #expect(chars[14] == "7", "Expected version-7 nibble at position 14, got id=\(id)")
        // Variant nibble at position 19 should be 8, 9, a, or b (binary 10xx).
        let variant = chars[19]
        #expect(["8", "9", "a", "b"].contains(variant), "Expected RFC 9562 variant nibble, got \(variant) (id=\(id))")
        // Sortability: two IDs generated back-to-back should compare in order.
        let a = UUIDv7.generateString()
        // Tiny sleep to guarantee a millisecond tick between generations.
        Thread.sleep(forTimeInterval: 0.005)
        let b = UUIDv7.generateString()
        #expect(a < b, "UUIDv7 should be lexicographically sortable by time (a=\(a), b=\(b))")
    }

    @Test("trashItem sets state to trashed") func trashItemSetsStateToTrashed() async throws {
        let store = try await makeStore()
        let item = try await store.createItem(noteInput())
        try await store.trashItem(id: item.id)
        let fetched = try await store.fetchItem(id: item.id)
        #expect(fetched.state == .trashed)
    }

    @Test("restoreItem sets state back to active") func restoreItemSetsStateBackToActive() async throws {
        let store = try await makeStore()
        let item = try await store.createItem(noteInput())
        try await store.trashItem(id: item.id)
        let restored = try await store.restoreItem(id: item.id)
        #expect(restored.state == .active)
    }

    @Test("transitionItem sets arbitrary state") func transitionItemSetsArbitraryState() async throws {
        let store = try await makeStore()
        let item = try await store.createItem(noteInput())
        let archived = try await store.transitionItem(id: item.id, to: .archived)
        #expect(archived.state == .archived)
    }

    @Test("itemStats counts by state") func itemStatsCountsByState() async throws {
        let store = try await makeStore()
        _ = try await store.createItem(noteInput(body: "1"))
        _ = try await store.createItem(noteInput(body: "2"))
        let trashed = try await store.createItem(noteInput(body: "3"))
        try await store.trashItem(id: trashed.id)
        let stats = try await store.itemStats()
        #expect(stats["active"] == 2)
        #expect(stats["trashed"] == 1)
    }

    @Test("purgeItem removes item permanently") func purgeItemRemovesItemPermanently() async throws {
        let store = try await makeStore()
        let item = try await store.createItem(noteInput())
        try await store.purgeItem(id: item.id)
        do {
            _ = try await store.fetchItem(id: item.id)
            Issue.record("Expected NotFoundError after purge")
        } catch is NotFoundError { }
    }

    // MARK: - Edge CRUD

    @Test("createEdge and fetchEdgesFromSource") func createEdgeAndFetchEdgesFromSource() async throws {
        let store = try await makeStore()
        let a = try await store.createItem(noteInput(body: "A"))
        let b = try await store.createItem(noteInput(body: "B"))
        let edge = try await store.createEdge(
            source: a.id, target: b.id,
            edgeType: "about", properties: nil
        )
        #expect(edge.sourceId == a.id)
        #expect(edge.targetId == b.id)
        #expect(edge.edgeType == "about")

        let edges = try await store.fetchEdgesFromSource(
            sourceId: a.id, edgeType: nil, cursor: nil, limit: nil
        )
        #expect(edges.data.map(\.id).contains(edge.id))
    }

    @Test("fetchEdgesToTarget returns inbound edges") func fetchEdgesToTargetReturnsInboundEdges() async throws {
        let store = try await makeStore()
        let a = try await store.createItem(noteInput(body: "A"))
        let b = try await store.createItem(noteInput(body: "B"))
        let edge = try await store.createEdge(
            source: a.id, target: b.id,
            edgeType: "about", properties: nil
        )
        let backrefs = try await store.fetchEdgesToTarget(
            targetId: b.id, edgeType: nil, cursor: nil, limit: nil
        )
        #expect(backrefs.data.map(\.id).contains(edge.id))
    }

    @Test("fetchEdgesFromSource filters by edgeType") func fetchEdgesFromSourceFiltersByEdgeType() async throws {
        let store = try await makeStore()
        let a = try await store.createItem(noteInput())
        let b = try await store.createItem(noteInput())
        let c = try await store.createItem(noteInput())
        _ = try await store.createEdge(source: a.id, target: b.id, edgeType: "about", properties: nil)
        _ = try await store.createEdge(source: a.id, target: c.id, edgeType: "references", properties: nil)

        let aboutEdges = try await store.fetchEdgesFromSource(
            sourceId: a.id, edgeType: "about", cursor: nil, limit: nil
        )
        #expect(aboutEdges.data.count == 1)
        #expect(aboutEdges.data[0].edgeType == "about")
    }

    @Test("attached-to edge round-trips through createEdge + fetchEdgesFromSource")
    func attachedToEdgeRoundTrips() async throws {
        let store = try await makeStore()
        let attachment = try await store.createItem(noteInput())
        let host = try await store.createItem(noteInput())
        let edge = try await store.createEdge(
            source: attachment.id, target: host.id,
            edgeType: "attached-to", properties: nil
        )

        let outbound = try await store.fetchEdgesFromSource(
            sourceId: attachment.id, edgeType: "attached-to", cursor: nil, limit: nil
        )
        #expect(outbound.data.map(\.id) == [edge.id])
        #expect(outbound.data[0].targetId == host.id)
    }

    @Test("updateEdge replaces properties") func updateEdgeReplacesProperties() async throws {
        let store = try await makeStore()
        let a = try await store.createItem(noteInput())
        let b = try await store.createItem(noteInput())
        let edge = try await store.createEdge(
            source: a.id, target: b.id, edgeType: "about",
            properties: ["note": .string("old")]
        )
        let updated = try await store.updateEdge(
            id: edge.id,
            properties: ["note": .string("new")]
        )
        #expect(updated.properties["note"] == .string("new"))
    }

    @Test("deleteEdge removes edge") func deleteEdgeRemovesEdge() async throws {
        let store = try await makeStore()
        let a = try await store.createItem(noteInput())
        let b = try await store.createItem(noteInput())
        let edge = try await store.createEdge(
            source: a.id, target: b.id, edgeType: "about", properties: nil
        )
        try await store.deleteEdge(id: edge.id)
        let edges = try await store.fetchEdgesFromSource(
            sourceId: a.id, edgeType: nil, cursor: nil, limit: nil
        )
        #expect(!edges.data.map(\.id).contains(edge.id))
    }

    // MARK: - Metadata CRUD

    @Test("fetchMetadata returns empty metadata for unknown item") func fetchMetadataReturnsEmptyMetadataForUnknownItem() async throws {
        let store = try await makeStore()
        let meta = try await store.fetchMetadata(itemId: "ghost")
        #expect(meta.tags.isEmpty)
        #expect(meta.extensions.isEmpty)
    }

    @Test("setMetadata replaces tags") func setMetadataReplacesTags() async throws {
        let store = try await makeStore()
        let item = try await store.createItem(noteInput())
        _ = try await store.setMetadata(itemId: item.id, input: MetadataInput(tags: ["a", "b"]))
        let meta = try await store.fetchMetadata(itemId: item.id)
        #expect(Set(meta.tags) == ["a", "b"])
    }

    @Test("mergeMetadata unions tags") func mergeMetadataUnionsTags() async throws {
        let store = try await makeStore()
        let item = try await store.createItem(noteInput())
        _ = try await store.setMetadata(itemId: item.id, input: MetadataInput(tags: ["a"]))
        _ = try await store.mergeMetadata(itemId: item.id, input: MetadataInput(tags: ["b", "c"]))
        let meta = try await store.fetchMetadata(itemId: item.id)
        #expect(Set(meta.tags) == ["a", "b", "c"])
    }

    @Test("addTags unions with existing") func addTagsUnionsWithExisting() async throws {
        let store = try await makeStore()
        let item = try await store.createItem(noteInput())
        _ = try await store.addTags(itemId: item.id, tags: ["x"])
        _ = try await store.addTags(itemId: item.id, tags: ["y", "x"])
        let meta = try await store.fetchMetadata(itemId: item.id)
        #expect(Set(meta.tags) == ["x", "y"])
    }

    @Test("removeTag removes single tag") func removeTagRemovesSingleTag() async throws {
        let store = try await makeStore()
        let item = try await store.createItem(noteInput())
        _ = try await store.setMetadata(itemId: item.id, input: MetadataInput(tags: ["a", "b", "c"]))
        try await store.removeTag(itemId: item.id, tag: "b")
        let meta = try await store.fetchMetadata(itemId: item.id)
        #expect(Set(meta.tags) == ["a", "c"])
    }

    // MARK: - listTags (local aggregation)

    @Test("listTags on empty store returns empty array") func listTagsEmpty() async throws {
        let store = try await makeStore()
        let tags = try await store.listTags()
        #expect(tags.isEmpty)
    }

    @Test("listTags aggregates across items, sorted count desc then tag asc") func listTagsAggregates() async throws {
        let store = try await makeStore()
        let a = try await store.createItem(noteInput(body: "A"))
        let b = try await store.createItem(noteInput(body: "B"))
        let c = try await store.createItem(noteInput(body: "C"))
        _ = try await store.setMetadata(itemId: a.id, input: MetadataInput(tags: ["work", "dev"]))
        _ = try await store.setMetadata(itemId: b.id, input: MetadataInput(tags: ["work", "dev"]))
        _ = try await store.setMetadata(itemId: c.id, input: MetadataInput(tags: ["work"]))

        let tags = try await store.listTags()
        #expect(tags == [
            TagWithCount(tag: "work", count: 3),
            TagWithCount(tag: "dev", count: 2),
        ])
    }

    @Test("listTags excludes trashed items") func listTagsExcludesTrashed() async throws {
        let store = try await makeStore()
        let keep = try await store.createItem(noteInput(body: "keep"))
        let gone = try await store.createItem(noteInput(body: "gone"))
        _ = try await store.setMetadata(itemId: keep.id, input: MetadataInput(tags: ["shared"]))
        _ = try await store.setMetadata(itemId: gone.id, input: MetadataInput(tags: ["shared"]))
        try await store.trashItem(id: gone.id)

        let tags = try await store.listTags()
        #expect(tags == [TagWithCount(tag: "shared", count: 1)])
    }

    @Test("listTags includes archived items") func listTagsIncludesArchived() async throws {
        let store = try await makeStore()
        let item = try await store.createItem(noteInput())
        _ = try await store.setMetadata(itemId: item.id, input: MetadataInput(tags: ["keep"]))
        _ = try await store.transitionItem(id: item.id, to: .archived)

        let tags = try await store.listTags()
        #expect(tags == [TagWithCount(tag: "keep", count: 1)])
    }

    @Test("listTags tie-breaks alphabetically") func listTagsTieBreaks() async throws {
        let store = try await makeStore()
        let a = try await store.createItem(noteInput(body: "A"))
        let b = try await store.createItem(noteInput(body: "B"))
        _ = try await store.setMetadata(itemId: a.id, input: MetadataInput(tags: ["banana"]))
        _ = try await store.setMetadata(itemId: b.id, input: MetadataInput(tags: ["apple"]))

        let tags = try await store.listTags()
        #expect(tags.map(\.tag) == ["apple", "banana"])
    }

    @Test("listTags ignores items without metadata rows") func listTagsIgnoresMetadataless() async throws {
        let store = try await makeStore()
        _ = try await store.createItem(noteInput())
        let tagged = try await store.createItem(noteInput())
        _ = try await store.setMetadata(itemId: tagged.id, input: MetadataInput(tags: ["x"]))

        let tags = try await store.listTags()
        #expect(tags == [TagWithCount(tag: "x", count: 1)])
    }

    // MARK: - fetchEdgesToTargets (batched backrefs)

    @Test("fetchEdgesToTargets empty input returns empty dict") func fetchEdgesToTargetsEmpty() async throws {
        let store = try await makeStore()
        let result = try await store.fetchEdgesToTargets(targetIds: [], edgeType: nil, limit: nil)
        #expect(result.isEmpty)
    }

    @Test("fetchEdgesToTargets groups edges by target id, includes empty keys") func fetchEdgesToTargetsGroups() async throws {
        let store = try await makeStore()
        let src = try await store.createItem(noteInput(body: "src"))
        let t1 = try await store.createItem(noteInput(body: "t1"))
        let t2 = try await store.createItem(noteInput(body: "t2"))
        let t3 = try await store.createItem(noteInput(body: "t3"))
        _ = try await store.createEdge(source: src.id, target: t1.id, edgeType: "about", properties: nil)
        _ = try await store.createEdge(source: src.id, target: t1.id, edgeType: "about", properties: nil)
        _ = try await store.createEdge(source: src.id, target: t2.id, edgeType: "about", properties: nil)
        // t3 has no inbound edges.

        let result = try await store.fetchEdgesToTargets(
            targetIds: [t1.id, t2.id, t3.id], edgeType: nil, limit: nil
        )

        #expect(result[t1.id]?.count == 2)
        #expect(result[t2.id]?.count == 1)
        #expect(result[t3.id]?.isEmpty == true)
    }

    @Test("fetchEdgesToTargets filters by edgeType") func fetchEdgesToTargetsFiltersType() async throws {
        let store = try await makeStore()
        let src = try await store.createItem(noteInput())
        let target = try await store.createItem(noteInput())
        _ = try await store.createEdge(source: src.id, target: target.id, edgeType: "about", properties: nil)
        _ = try await store.createEdge(source: src.id, target: target.id, edgeType: "references", properties: nil)

        let aboutOnly = try await store.fetchEdgesToTargets(
            targetIds: [target.id], edgeType: "about", limit: nil
        )
        #expect(aboutOnly[target.id]?.count == 1)
        #expect(aboutOnly[target.id]?.first?.edgeType == "about")
    }

    @Test("fetchEdgesToTargets caps per-target with limit") func fetchEdgesToTargetsLimit() async throws {
        let store = try await makeStore()
        let src = try await store.createItem(noteInput())
        let target = try await store.createItem(noteInput())
        for _ in 0..<5 {
            _ = try await store.createEdge(source: src.id, target: target.id, edgeType: "about", properties: nil)
        }
        let capped = try await store.fetchEdgesToTargets(
            targetIds: [target.id], edgeType: nil, limit: 3
        )
        #expect(capped[target.id]?.count == 3)
    }

    @Test("fetchEdgesToTargets collapses duplicates") func fetchEdgesToTargetsDedup() async throws {
        let store = try await makeStore()
        let target = try await store.createItem(noteInput())
        let result = try await store.fetchEdgesToTargets(
            targetIds: [target.id, target.id], edgeType: nil, limit: nil
        )
        #expect(result.keys.count == 1)
    }

    // MARK: - Pure-local mode via MarfaClient.local(path:)

    @Suite("Pure-local client (MarfaClient.local)")
    struct PureLocalClientTests {

        private func client() async throws -> MarfaClient { try await MarfaClient.local(path: ":memory:") }

        @Test("create and get item") func createAndGet() async throws {
            let client = try await client()
            let input = CreateItemInput(
                type: "core.note",
                properties: ["body": .string("Hello from local")]
            )
            let created = try await client.items.create(input)
            #expect(!created.id.isEmpty)
            let fetched = try await client.items.get(id: created.id)
            #expect(fetched.id == created.id)
            #expect(fetched.properties["body"] == .string("Hello from local"))
        }

        @Test("list items") func listItems() async throws {
            let client = try await client()
            _ = try await client.items.create(
                CreateItemInput(type: "core.note", properties: ["body": .string("1")])
            )
            _ = try await client.items.create(
                CreateItemInput(type: "core.task", properties: ["title": .string("Buy milk")])
            )
            let all = try await client.items.list()
            #expect(all.data.count == 2)
        }

        @Test("update item") func updateItem() async throws {
            let client = try await client()
            let item = try await client.items.create(
                CreateItemInput(type: "core.note", properties: ["body": .string("old")])
            )
            let updated = try await client.items.update(
                id: item.id,
                properties: ["body": .string("new")]
            )
            #expect(updated.properties["body"] == .string("new"))
            #expect(updated.version == 2)
        }

        @Test("delete (trash) and restore item") func deleteAndRestore() async throws {
            let client = try await client()
            let item = try await client.items.create(
                CreateItemInput(type: "core.note", properties: ["body": .string("x")])
            )
            try await client.items.delete(id: item.id)
            let trashed = try await client.items.get(id: item.id)
            #expect(trashed.state == .trashed)

            let restored = try await client.items.restore(id: item.id)
            #expect(restored.state == .active)
        }

        @Test("create edge and list from source") func createEdge() async throws {
            let client = try await client()
            let a = try await client.items.create(
                CreateItemInput(type: "core.note", properties: ["body": .string("A")])
            )
            let b = try await client.items.create(
                CreateItemInput(type: "core.note", properties: ["body": .string("B")])
            )
            let edge = try await client.edges.create(
                source: a.id, target: b.id, edgeType: "about"
            )
            let edges = try await client.items.edges(id: a.id)
            #expect(edges.data.map(\.id).contains(edge.id))
        }

        @Test("metadata: set, get, remove tag") func metadata() async throws {
            let client = try await client()
            let item = try await client.items.create(
                CreateItemInput(type: "core.note", properties: ["body": .string("x")])
            )
            _ = try await client.metadata.set(
                itemId: item.id, input: MetadataInput(tags: ["alpha", "beta"])
            )
            let meta = try await client.metadata.get(itemId: item.id)
            #expect(Set(meta.tags) == ["alpha", "beta"])

            try await client.metadata.removeTag(itemId: item.id, tag: "alpha")
            let after = try await client.metadata.get(itemId: item.id)
            #expect(Set(after.tags) == ["beta"])
        }

        @Test("stats reflects item counts") func stats() async throws {
            let client = try await client()
            _ = try await client.items.create(
                CreateItemInput(type: "core.note", properties: ["body": .string("a")])
            )
            _ = try await client.items.create(
                CreateItemInput(type: "core.note", properties: ["body": .string("b")])
            )
            let stats = try await client.items.stats()
            #expect((stats["active"] ?? 0) >= 2)
        }

        @Test("get throws NotFoundError for missing item") func getMissing() async throws {
            let client = try await client()
            do {
                _ = try await client.items.get(id: "does-not-exist")
                Issue.record("Expected NotFoundError")
            } catch let e as NotFoundError {
                #expect(e.status == 404)
            }
        }
    }
}
