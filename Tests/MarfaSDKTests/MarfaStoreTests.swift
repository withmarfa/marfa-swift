import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// Tests for ``MarfaStore``, ``ItemQuery``, ``TypedItemQuery``, ``SingleItemQuery``,
/// and ``EdgesQuery``.
///
/// All tests run in an in-memory SQLite store. Because the query objects are
/// `@MainActor @Observable`, all test bodies run with `@MainActor` isolation
/// so Swift Testing routes them onto the main thread.
// Every wait in this suite is a poll with no test-owned deadline, so this
// trait is what stops a starved condition hanging the run. It is coarse on
// purpose: a minute that names itself a timeout beats half a second that
// names the wrong thing.
@Suite("MarfaStore reactive queries", .timeLimit(.minutes(1)))
@MainActor
struct MarfaStoreTests {

    // MARK: - Helpers

    private func makeClient() async throws -> MarfaClient {
        try await MarfaClient.local(path: ":memory:")
    }

    private func noteInput(body: String) -> CreateItemInput {
        CreateItemInput(type: "core.note", properties: ["body": .string(body)])
    }

    // MARK: - makeStore

    @Test("makeStore returns non-nil for local client") func makeStoreLocal() async throws {
        let client = try await makeClient()
        let store = client.makeStore()
        #expect(store != nil)
    }

    @Test("makeStore returns nil for network-only client") func makeStoreNetwork() {
        let client = MarfaClient(
            url: URL(string: "https://example.com")!,
            apiKey: "key"
        )
        let store = client.makeStore()
        #expect(store == nil)
    }

    // MARK: - ItemQuery

    @Test("ItemQuery starts loading then delivers items") func itemQueryBasic() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        // Create two items via the client namespace (write to local store).
        _ = try await client.items.create(noteInput(body: "Alpha"))
        _ = try await client.items.create(noteInput(body: "Beta"))

        let query = store.query()

        // Wait for the didSave-driven refetch to land.
        try await awaitCondition(description: "query.items.count >= 2") { query.items.count >= 2 }

        #expect(query.items.count == 2)
        #expect(query.isLoading == false)
        #expect(query.error == nil)
        query.stop()
    }

    @Test("ItemQuery filters by type") func itemQueryFilterType() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        _ = try await client.items.create(noteInput(body: "Note"))
        _ = try await client.items.create(
            CreateItemInput(type: "core.task", properties: ["title": .string("Task")])
        )

        let query = store.query(filters: ListFilters(type: "core.note"))
        try await awaitCondition(description: "query.items.count >= 1") { query.items.count >= 1 }

        #expect(query.items.count == 1)
        #expect(query.items[0].type == "core.note")
        query.stop()
    }

    @Test("ItemQuery filters by state") func itemQueryFilterState() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let active = try await client.items.create(noteInput(body: "Keep"))
        let toTrash = try await client.items.create(noteInput(body: "Trash"))
        try await client.items.delete(id: toTrash.id)

        let query = store.query(filters: ListFilters(state: .active))
        try await awaitCondition(description: "!query.isLoading") { !query.isLoading }

        let ids = query.items.map(\.id)
        #expect(ids.contains(active.id))
        #expect(!ids.contains(toTrash.id))
        query.stop()
    }

    @Test("ItemQuery updates when a new item is created") func itemQueryLiveUpdate() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let query = store.query(filters: ListFilters(type: "core.note"))
        // Wait for first (empty) result.
        try await awaitCondition(description: "!query.isLoading") { !query.isLoading }
        #expect(query.items.isEmpty)

        // Insert a note — the observation should fire and update `items`.
        _ = try await client.items.create(noteInput(body: "Live update"))
        try await awaitCondition(description: "query.items.count == 1") { query.items.count == 1 }

        #expect(query.items[0].properties["body"] == .string("Live update"))
        query.stop()
    }

    @Test("ItemQuery updates when an item is deleted") func itemQueryLiveDelete() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let item = try await client.items.create(noteInput(body: "Will be trashed"))
        let query = store.query()
        try await awaitCondition(description: "query.items.count == 1") { query.items.count == 1 }

        // Trash the item — it changes state, so the query sees 1 item still (state changed).
        // Use a state filter to confirm.
        let activeQuery = store.query(filters: ListFilters(state: .active))
        try await awaitCondition(description: "activeQuery.items.count == 1") { activeQuery.items.count == 1 }

        try await client.items.delete(id: item.id)
        try await awaitCondition(description: "activeQuery.items.isEmpty") { activeQuery.items.isEmpty }

        query.stop()
        activeQuery.stop()
    }

    // MARK: - SingleItemQuery

    @Test("SingleItemQuery returns item by ID") func singleItemQuery() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let created = try await client.items.create(noteInput(body: "Single"))
        let query = store.queryItem(id: created.id)
        try await awaitCondition(description: "query.item != nil") { query.item != nil }

        #expect(query.item?.id == created.id)
        #expect(query.item?.properties["body"] == .string("Single"))
        query.stop()
    }

    @Test("SingleItemQuery returns nil for non-existent item") func singleItemQueryMissing() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let query = store.queryItem(id: "does-not-exist")
        try await awaitCondition(description: "!query.isLoading") { !query.isLoading }

        #expect(query.item == nil)
        #expect(query.error == nil)
        query.stop()
    }

    @Test("SingleItemQuery updates on property change") func singleItemQueryUpdate() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let created = try await client.items.create(noteInput(body: "Original"))
        let query = store.queryItem(id: created.id)
        try await awaitCondition(description: "query.item != nil") { query.item != nil }

        _ = try await client.items.update(
            id: created.id,
            properties: ["body": .string("Updated")]
        )
        try await awaitCondition(description: "query.item?.properties[\"body\"] == .string(\"Updated\")") {
            query.item?.properties["body"] == .string("Updated")
        }

        query.stop()
    }

    // MARK: - TypedItemQuery

    @Test("TypedItemQuery returns CoreNote instances") func typedItemQuery() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        _ = try await client.items.create(noteInput(body: "Typed note"))
        _ = try await client.items.create(
            CreateItemInput(type: "core.task", properties: ["title": .string("Task")])
        )

        let query = store.typedQuery(CoreNote.self)
        try await awaitCondition(description: "query.items.count >= 1") { query.items.count >= 1 }

        #expect(query.items.count == 1)
        #expect(query.items[0].body == "Typed note")
        query.stop()
    }

    @Test("TypedItemQuery is empty for wrong type") func typedItemQueryWrongType() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        _ = try await client.items.create(noteInput(body: "Note"))

        let query = store.typedQuery(CoreTask.self)
        try await awaitCondition(description: "!query.isLoading") { !query.isLoading }

        #expect(query.items.isEmpty)
        query.stop()
    }

    // MARK: - EdgesQuery

    @Test("EdgesQuery returns outbound edges") func edgesQueryReturnsOutboundEdges() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let a = try await client.items.create(noteInput(body: "A"))
        let b = try await client.items.create(noteInput(body: "B"))
        _ = try await client.edges.create(source: a.id, target: b.id, edgeType: "about")

        let query = store.queryEdges(from: a.id)
        try await awaitCondition(description: "query.edges.count >= 1") { query.edges.count >= 1 }

        #expect(query.edges.count == 1)
        #expect(query.edges[0].edgeType == "about")
        #expect(query.edges[0].sourceId == a.id)
        #expect(query.edges[0].targetId == b.id)
        query.stop()
    }

    @Test("EdgesQuery filters by edgeType") func edgesQueryFiltersByEdgeType() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let a = try await client.items.create(noteInput(body: "A"))
        let b = try await client.items.create(noteInput(body: "B"))
        let c = try await client.items.create(noteInput(body: "C"))
        _ = try await client.edges.create(source: a.id, target: b.id, edgeType: "about")
        _ = try await client.edges.create(source: a.id, target: c.id, edgeType: "references")

        let aboutQuery = store.queryEdges(from: a.id, edgeType: "about")
        try await awaitCondition(description: "aboutQuery.edges.count >= 1") { aboutQuery.edges.count >= 1 }

        #expect(aboutQuery.edges.count == 1)
        #expect(aboutQuery.edges[0].edgeType == "about")
        aboutQuery.stop()
    }

    @Test("EdgesQuery updates when edge is deleted") func edgesQueryUpdatesWhenEdgeIsDeleted() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let a = try await client.items.create(noteInput(body: "A"))
        let b = try await client.items.create(noteInput(body: "B"))
        let edge = try await client.edges.create(source: a.id, target: b.id, edgeType: "about")

        let query = store.queryEdges(from: a.id)
        try await awaitCondition(description: "query.edges.count == 1") { query.edges.count == 1 }

        try await client.edges.delete(id: edge.id)
        try await awaitCondition(description: "query.edges.isEmpty") { query.edges.isEmpty }

        query.stop()
    }

    // MARK: - TagsQuery

    @Test("TagsQuery emits aggregated tag counts") func tagsQueryAggregates() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let a = try await client.items.create(noteInput(body: "A"))
        let b = try await client.items.create(noteInput(body: "B"))
        _ = try await client.metadata.addTags(itemId: a.id, tags: ["work", "dev"])
        _ = try await client.metadata.addTags(itemId: b.id, tags: ["work"])

        let query = store.queryTags()
        try await awaitCondition(description: "query.tags.count >= 2") { query.tags.count >= 2 }

        #expect(query.tags == [
            TagWithCount(tag: "work", count: 2),
            TagWithCount(tag: "dev", count: 1),
        ])
        query.stop()
    }

    @Test("TagsQuery updates live when a tag is added") func tagsQueryLiveAdd() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let item = try await client.items.create(noteInput(body: "live"))
        let query = store.queryTags()
        try await awaitCondition(description: "!query.isLoading") { !query.isLoading }
        #expect(query.tags.isEmpty)

        _ = try await client.metadata.addTags(itemId: item.id, tags: ["fresh"])
        try await awaitCondition(description: "!query.tags.isEmpty") { !query.tags.isEmpty }

        #expect(query.tags == [TagWithCount(tag: "fresh", count: 1)])
        query.stop()
    }

    @Test("TagsQuery drops trashed items live") func tagsQueryLiveTrash() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let item = try await client.items.create(noteInput(body: "soon-trashed"))
        _ = try await client.metadata.addTags(itemId: item.id, tags: ["tmp"])

        let query = store.queryTags()
        try await awaitCondition(description: "query.tags.count == 1") { query.tags.count == 1 }

        try await client.items.delete(id: item.id)
        try await awaitCondition(description: "query.tags.isEmpty") { query.tags.isEmpty }

        query.stop()
    }

    // MARK: - TypesInDataQuery

    @Test("TypesInDataQuery returns distinct types, sorted") func typesInDataDistinct() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        _ = try await client.items.create(noteInput(body: "one"))
        _ = try await client.items.create(noteInput(body: "two"))
        _ = try await client.items.create(
            CreateItemInput(type: "core.bookmark", properties: ["url": .string("https://example.test")])
        )

        let query = store.queryTypesInData()
        try await awaitCondition(description: "query.types.count == 2") { query.types.count == 2 }

        #expect(query.types == ["core.bookmark", "core.note"])
        query.stop()
    }

    @Test("TypesInDataQuery picks up a new type live") func typesInDataLiveAdd() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        _ = try await client.items.create(noteInput(body: "only a note"))
        let query = store.queryTypesInData()
        try await awaitCondition(description: "query.types == [\"core.note\"]") { query.types == ["core.note"] }

        _ = try await client.items.create(
            CreateItemInput(type: "core.task", properties: ["title": .string("later")])
        )
        try await awaitCondition(description: "query.types.count == 2") { query.types.count == 2 }

        #expect(query.types == ["core.note", "core.task"])
        query.stop()
    }

    /// The deliberate divergence from an unfiltered item walk. A type whose
    /// only items are trashed is not a type the space holds, and `TagsQuery`
    /// already excludes those rows — so a consumer building one filter list
    /// from both had the type of a trashed item offered while its tags were
    /// not.
    @Test("TypesInDataQuery excludes trashed items") func typesInDataExcludesTrashed() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        _ = try await client.items.create(noteInput(body: "stays"))
        let doomed = try await client.items.create(
            CreateItemInput(type: "core.bookmark", properties: ["url": .string("https://example.test")])
        )

        let query = store.queryTypesInData()
        try await awaitCondition(description: "query.types.count == 2") { query.types.count == 2 }

        try await client.items.delete(id: doomed.id)
        try await awaitCondition(description: "query.types.count == 1") { query.types.count == 1 }

        #expect(query.types == ["core.note"])
        query.stop()
    }

    /// The second deliberate divergence, on the same reasoning as trashed
    /// rows. This list is a filter menu, so a chip has to name something the
    /// app's own list will show — and `items.list()` leaves `system.*` rows
    /// out unless a caller names a system type outright.
    ///
    /// It became reachable when the import began asking the server for system
    /// rows. Before that the prune deleted them again on every re-import, so
    /// the store held them only between a stream frame and the next import.
    @Test("TypesInDataQuery excludes system.* types") func typesInDataExcludesSystemTypes() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        _ = try await client.items.create(noteInput(body: "a note someone wrote"))
        _ = try await client.items.create(
            CreateItemInput(type: "system.activity", properties: [
                "summary": .string("a sync happened"),
                "severity": .string("info"),
                "connection_id": .string("conn-1"),
            ])
        )
        _ = try await client.items.create(
            CreateItemInput(type: "system.connection", properties: [
                "kind": .string("integration"),
                "status": .string("active"),
                "granted_at": .string("2026-09-03T09:00:00Z"),
            ])
        )

        // Waits for the first refetch to settle, which is a weaker condition
        // than the one being asserted on purpose. All three rows are written
        // before the query exists, so the first pass sees the final state —
        // and waiting on the assertion itself would report a wrong answer as
        // a timeout rather than as the diff it is.
        let query = store.queryTypesInData()
        try await awaitCondition(description: "the first refetch settled") {
            !query.isLoading
        }

        // On the monorepo's own production numbers a real device holds several
        // thousand activity rows against a few hundred of everything else, so
        // the menu this feeds would have been mostly operational chips.
        #expect(query.types == ["core.note"])
        query.stop()
    }

    /// The query is only affordable because it never decodes an item's
    /// properties, and no test can observe that directly. What this pins is the
    /// correctness half: a row whose properties blob dwarfs every other column
    /// still reports its type. A future attempt to narrow the fetch further
    /// breaks here if it narrows it wrongly.
    ///
    /// `FetchDescriptor.propertiesToFetch` was tried and removed. It changes
    /// nothing observable — SwiftData faults an unlisted property on access, so
    /// asking for the wrong column left every test in this suite passing, which
    /// makes it a claim no test can hold.
    @Test("TypesInDataQuery reads the type of an item with a large body") func typesInDataLargeBody() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        _ = try await client.items.create(
            CreateItemInput(
                type: "core.note",
                // Large, but inside the bound the server puts on a string:
                // this test is about the query not decoding the body, and a
                // body no server would accept would not prove that.
                properties: ["body": .string(String(repeating: "long. ", count: 16_000))]
            )
        )

        let query = store.queryTypesInData()
        try await awaitCondition(description: "!query.isLoading") { !query.isLoading }

        #expect(query.types == ["core.note"])
        query.stop()
    }

    // MARK: - BackrefsQuery

    @Test("BackrefsQuery groups inbound edges by target") func backrefsQueryGroups() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let src = try await client.items.create(noteInput(body: "src"))
        let t1 = try await client.items.create(noteInput(body: "t1"))
        let t2 = try await client.items.create(noteInput(body: "t2"))
        _ = try await client.edges.create(source: src.id, target: t1.id, edgeType: "in-thread")
        _ = try await client.edges.create(source: src.id, target: t1.id, edgeType: "in-thread")
        _ = try await client.edges.create(source: src.id, target: t2.id, edgeType: "in-thread")

        let query = store.queryBackrefs(to: [t1.id, t2.id], edgeType: "in-thread")
        try await awaitCondition(description: "(query.edgesByTarget[t1.id]?.count ?? 0) == 2") {
            (query.edgesByTarget[t1.id]?.count ?? 0) == 2
        }

        #expect(query.edgesByTarget[t2.id]?.count == 1)
        query.stop()
    }

    @Test("BackrefsQuery updates when an edge is deleted") func backrefsQueryLiveDelete() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let src = try await client.items.create(noteInput(body: "src"))
        let tgt = try await client.items.create(noteInput(body: "tgt"))
        let edge = try await client.edges.create(
            source: src.id, target: tgt.id, edgeType: "about"
        )

        let query = store.queryBackrefs(to: [tgt.id])
        try await awaitCondition(description: "query.edgesByTarget[tgt.id]?.count == 1") {
            query.edgesByTarget[tgt.id]?.count == 1
        }

        try await client.edges.delete(id: edge.id)
        try await awaitCondition(description: "query.edgesByTarget[tgt.id]?.isEmpty == true") {
            query.edgesByTarget[tgt.id]?.isEmpty == true
        }

        query.stop()
    }

    @Test("BackrefsQuery with empty targetIds loads immediately empty") func backrefsQueryEmpty() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let query = store.queryBackrefs(to: [])
        #expect(query.isLoading == false)
        #expect(query.edgesByTarget.isEmpty)
        query.stop()
    }

    @Test("BackrefsQuery keeps unknown target IDs with empty value") func backrefsQueryUnknownKeys() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let src = try await client.items.create(noteInput(body: "src"))
        let real = try await client.items.create(noteInput(body: "real"))
        _ = try await client.edges.create(source: src.id, target: real.id, edgeType: "about")

        let query = store.queryBackrefs(to: [real.id, "ghost-id"])
        try await awaitCondition(description: "query.edgesByTarget[real.id]?.count == 1") {
            query.edgesByTarget[real.id]?.count == 1
        }

        #expect(query.edgesByTarget["ghost-id"]?.isEmpty == true)
        query.stop()
    }

    // MARK: - ItemsWithMetadataQuery

    @Test("ItemsWithMetadataQuery pairs items with their metadata") func itemsWithMetadataPair() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let a = try await client.items.create(noteInput(body: "A"))
        let b = try await client.items.create(noteInput(body: "B"))
        _ = try await client.metadata.addTags(itemId: a.id, tags: ["work"])
        _ = try await client.metadata.addTags(itemId: b.id, tags: ["home", "work"])

        let query = store.queryItemsWithMetadata()
        try await awaitCondition(description: "query.items.count == 2") { query.items.count == 2 }

        let byId = Dictionary(uniqueKeysWithValues: query.items.map { ($0.item.id, $0) })
        #expect(Set(byId[a.id]?.metadata.tags ?? []) == ["work"])
        #expect(Set(byId[b.id]?.metadata.tags ?? []) == ["home", "work"])
        #expect(query.isLoading == false)
        query.stop()
    }

    @Test("ItemsWithMetadataQuery returns empty metadata for items with no metadata row") func itemsWithMetadataEmptyDefault() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let item = try await client.items.create(noteInput(body: "no tags"))

        let query = store.queryItemsWithMetadata()
        try await awaitCondition(description: "query.items.count == 1") { query.items.count == 1 }

        #expect(query.items.first?.item.id == item.id)
        #expect(query.items.first?.metadata.tags.isEmpty == true)
        #expect(query.items.first?.metadata.extensions.isEmpty == true)
        query.stop()
    }

    @Test("ItemsWithMetadataQuery updates live on item create") func itemsWithMetadataLiveCreate() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let query = store.queryItemsWithMetadata()
        try await awaitCondition(description: "!query.isLoading") { !query.isLoading }
        #expect(query.items.isEmpty)

        _ = try await client.items.create(noteInput(body: "fresh"))
        try await awaitCondition(description: "query.items.count == 1") { query.items.count == 1 }

        #expect(query.items.first?.metadata.tags.isEmpty == true)
        query.stop()
    }

    @Test("ItemsWithMetadataQuery updates live on tag add") func itemsWithMetadataLiveTagAdd() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let item = try await client.items.create(noteInput(body: "will be tagged"))

        let query = store.queryItemsWithMetadata()
        try await awaitCondition(description: "query.items.count == 1") { query.items.count == 1 }
        #expect(query.items.first?.metadata.tags.isEmpty == true)

        _ = try await client.metadata.addTags(itemId: item.id, tags: ["added"])
        try await awaitCondition(description: "query.items.first?.metadata.tags.contains(\"added\") == true") {
            query.items.first?.metadata.tags.contains("added") == true
        }

        #expect(query.items.first?.metadata.tags == ["added"])
        query.stop()
    }

    @Test("ItemsWithMetadataQuery honors type filter") func itemsWithMetadataTypeFilter() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        _ = try await client.items.create(noteInput(body: "note"))
        _ = try await client.items.create(
            CreateItemInput(type: "core.task", properties: ["title": .string("task")])
        )

        let query = store.queryItemsWithMetadata(filters: ListFilters(type: "core.note"))
        try await awaitCondition(description: "query.items.count == 1") { query.items.count == 1 }

        #expect(query.items.allSatisfy { $0.item.type == "core.note" })
        query.stop()
    }

    @Test("ItemsWithMetadataQuery honors limit") func itemsWithMetadataLimit() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        for i in 0..<5 {
            _ = try await client.items.create(noteInput(body: "n-\(i)"))
        }

        let query = store.queryItemsWithMetadata(filters: ListFilters(limit: 3))
        try await awaitCondition(description: "query.items.count == 3") { query.items.count == 3 }

        query.stop()
    }

    @Test("ItemsWithMetadataQuery drops item when trashed under state filter") func itemsWithMetadataStateFilter() async throws {
        let client = try await makeClient()
        guard let store = client.makeStore() else {
            Issue.record("Expected non-nil store"); return
        }

        let item = try await client.items.create(noteInput(body: "soon-trashed"))

        let query = store.queryItemsWithMetadata(filters: ListFilters(state: .active))
        try await awaitCondition(description: "query.items.count == 1") { query.items.count == 1 }

        try await client.items.delete(id: item.id)
        try await awaitCondition(description: "query.items.isEmpty") { query.items.isEmpty }

        query.stop()
    }
}
