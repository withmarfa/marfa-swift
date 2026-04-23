import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

/// Tests for ``LocalStore`` CRUD and ``MymeClient/local(path:)`` pure-local mode.
///
/// All tests use an in-memory SwiftData container so they leave no on-disk
/// artefacts and run safely in parallel.
@Suite("LocalStore")
struct LocalStoreTests {

    // MARK: - Helpers

    private func makeStore() async throws -> LocalStore {
        try await MymeSDKTest.makeInMemoryLocalStore()
    }

    private func makeLocalClient() async throws -> MymeClient {
        try await MymeClient.local(path: ":memory:")
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

    @Test("MymeClient.local(path:) creates a working client") func localClient() async throws {
        _ = try await makeLocalClient()
    }

    @Test("MymeClient.local(container:) creates a working client from a caller-built container") func localClientFromContainer() async throws {
        let container = try MymeModelContainer.make(path: ":memory:")
        let client = try await MymeClient.local(container: container)
        let item = try await client.items.create(noteInput(body: "hello"))
        #expect(item.properties["body"] == .string("hello"))
        // Round-trip: fetch through a second client on the same container
        // to prove the SDK honours the injected store (not a fresh one).
        let second = try await MymeClient.local(container: container)
        let fetched = try await second.items.get(id: item.id)
        #expect(fetched.id == item.id)
    }

    @Test("MymeModelContainer.make(path:cloudKitDatabase:) defaults to .none") func containerDefaultsToNoneCloudKit() throws {
        // Smoke-level: the in-memory branch forces `.none` regardless,
        // but exercising the default-argument path guards against
        // accidental signature regressions.
        _ = try MymeModelContainer.make(path: ":memory:")
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
        #expect(result.hasMore == false)
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

    @Test("updateItem with no library override preserves existing flag") func updateItemPreservesLibraryWhenAbsent() async throws {
        let store = try await makeStore()
        let input = CreateItemInput(
            type: "core.note",
            properties: ["body": .string("x")],
            library: true
        )
        let item = try await store.createItem(input)
        #expect(item.library == true)
        let updated = try await store.updateItem(
            id: item.id,
            properties: ["body": .string("y")]
        )
        #expect(updated.library == true)
    }

    @Test("updateItem with library override applies the new value") func updateItemAppliesLibraryOverride() async throws {
        let store = try await makeStore()
        let item = try await store.createItem(noteInput())
        #expect(item.library == false)
        let updated = try await store.updateItem(
            id: item.id,
            properties: [:],
            library: true
        )
        #expect(updated.library == true)
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
        let archived = try await store.transitionItem(id: item.id, to: "archived")
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
            sourceId: a.id, edgeType: nil, limit: nil
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
            targetId: b.id, edgeType: nil, limit: nil
        )
        #expect(backrefs.data.map(\.id).contains(edge.id))
    }

    @Test("fetchEdgesFromSource filters by edgeType") func fetchEdgesFromSourceFiltersByEdgeType() async throws {
        let store = try await makeStore()
        let a = try await store.createItem(noteInput())
        let b = try await store.createItem(noteInput())
        let c = try await store.createItem(noteInput())
        _ = try await store.createEdge(source: a.id, target: b.id, edgeType: "about", properties: nil)
        _ = try await store.createEdge(source: a.id, target: c.id, edgeType: "annotates", properties: nil)

        let aboutEdges = try await store.fetchEdgesFromSource(
            sourceId: a.id, edgeType: "about", limit: nil
        )
        #expect(aboutEdges.data.count == 1)
        #expect(aboutEdges.data[0].edgeType == "about")
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
            sourceId: a.id, edgeType: nil, limit: nil
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
        _ = try await store.transitionItem(id: item.id, to: "archived")

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
        _ = try await store.createEdge(source: src.id, target: target.id, edgeType: "annotates", properties: nil)

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

    // MARK: - Pure-local mode via MymeClient.local(path:)

    @Suite("Pure-local client (MymeClient.local)")
    struct PureLocalClientTests {

        private func client() async throws -> MymeClient { try await MymeClient.local(path: ":memory:") }

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
