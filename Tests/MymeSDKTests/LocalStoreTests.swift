import Testing
import Foundation
@testable import MymeSDK

/// Tests for ``LocalStore`` CRUD and ``MymeClient/local(path:)`` pure-local mode.
///
/// All tests use an in-memory SQLite database (`:memory:`) so they leave no
/// on-disk artefacts and run safely in parallel.
@Suite("LocalStore")
struct LocalStoreTests {

    // MARK: - Helpers

    private func makeStore() throws -> LocalStore {
        try LocalStore(path: ":memory:")
    }

    private func makeLocalClient() throws -> MymeClient {
        try MymeClient.local(path: ":memory:")
    }

    private func noteInput(body: String = "Hello", title: String? = nil) -> CreateItemInput {
        var props: [String: JSONValue] = ["body": .string(body)]
        if let title { props["title"] = .string(title) }
        return CreateItemInput(type: "core.note", properties: props)
    }

    // MARK: - Schema / lifecycle

    @Test("In-memory store opens without error") func openStore() throws {
        #expect(throws: Never.self) { try makeStore() }
    }

    @Test("MymeClient.local(path:) creates a working client") func localClient() throws {
        #expect(throws: Never.self) { try makeLocalClient() }
    }

    // MARK: - Item CRUD (via LocalStore directly)

    @Test("createItem generates an ID and stores the item") func createItem() async throws {
        let store = try makeStore()
        let input = noteInput(body: "My note")
        let item = try await store.createItem(input)

        #expect(!item.id.isEmpty)
        #expect(item.type == "core.note")
        #expect(item.properties["body"] == .string("My note"))
        #expect(item.state == .active)
        #expect(item.version == 1)
    }

    @Test("fetchItem returns stored item") func fetchItem() async throws {
        let store = try makeStore()
        let created = try await store.createItem(noteInput())
        let fetched = try await store.fetchItem(id: created.id)
        #expect(fetched.id == created.id)
        #expect(fetched.properties["body"] == created.properties["body"])
    }

    @Test("fetchItem throws NotFoundError for unknown ID") func fetchItemMissing() async throws {
        let store = try makeStore()
        do {
            _ = try await store.fetchItem(id: "no-such-id")
            Issue.record("Expected NotFoundError")
        } catch let e as NotFoundError {
            #expect(e.status == 404)
        }
    }

    @Test("fetchItems returns all created items") func fetchItems() async throws {
        let store = try makeStore()
        let a = try await store.createItem(noteInput(body: "A"))
        let b = try await store.createItem(noteInput(body: "B"))
        let result = try await store.fetchItems(filters: nil)
        let ids = result.data.map(\.id)
        #expect(ids.contains(a.id))
        #expect(ids.contains(b.id))
        #expect(result.hasMore == false)
    }

    @Test("fetchItems filters by type") func fetchItemsFiltersByType() async throws {
        let store = try makeStore()
        _ = try await store.createItem(noteInput())
        _ = try await store.createItem(CreateItemInput(type: "core.task", properties: ["title": "Task"]))
        let notes = try await store.fetchItems(filters: ListFilters(type: "core.note"))
        #expect(notes.data.allSatisfy { $0.type == "core.note" })
        #expect(notes.data.count == 1)
    }

    @Test("fetchItems filters by state") func fetchItemsFiltersByState() async throws {
        let store = try makeStore()
        let active = try await store.createItem(noteInput(body: "keep"))
        let toTrash = try await store.createItem(noteInput(body: "trash me"))
        try await store.trashItem(id: toTrash.id)
        let actives = try await store.fetchItems(filters: ListFilters(state: .active))
        #expect(actives.data.map(\.id).contains(active.id))
        #expect(!actives.data.map(\.id).contains(toTrash.id))
    }

    @Test("updateItem replaces properties and increments version") func updateItemReplacesPropertiesAndIncrementsVersion() async throws {
        let store = try makeStore()
        let item = try await store.createItem(noteInput(body: "original"))
        let updated = try await store.updateItem(
            id: item.id,
            properties: ["body": .string("revised"), "title": .string("New Title")]
        )
        #expect(updated.version == 2)
        #expect(updated.properties["body"] == .string("revised"))
        #expect(updated.properties["title"] == .string("New Title"))
    }

    @Test("trashItem sets state to trashed") func trashItemSetsStateToTrashed() async throws {
        let store = try makeStore()
        let item = try await store.createItem(noteInput())
        try await store.trashItem(id: item.id)
        let fetched = try await store.fetchItem(id: item.id)
        #expect(fetched.state == .trashed)
    }

    @Test("restoreItem sets state back to active") func restoreItemSetsStateBackToActive() async throws {
        let store = try makeStore()
        let item = try await store.createItem(noteInput())
        try await store.trashItem(id: item.id)
        let restored = try await store.restoreItem(id: item.id)
        #expect(restored.state == .active)
    }

    @Test("transitionItem sets arbitrary state") func transitionItemSetsArbitraryState() async throws {
        let store = try makeStore()
        let item = try await store.createItem(noteInput())
        let archived = try await store.transitionItem(id: item.id, to: "archived")
        #expect(archived.state == .archived)
    }

    @Test("itemStats counts by state") func itemStatsCountsByState() async throws {
        let store = try makeStore()
        _ = try await store.createItem(noteInput(body: "1"))
        _ = try await store.createItem(noteInput(body: "2"))
        let trashed = try await store.createItem(noteInput(body: "3"))
        try await store.trashItem(id: trashed.id)
        let stats = try await store.itemStats()
        #expect(stats["active"] == 2)
        #expect(stats["trashed"] == 1)
    }

    @Test("purgeItem removes item permanently") func purgeItemRemovesItemPermanently() async throws {
        let store = try makeStore()
        let item = try await store.createItem(noteInput())
        try await store.purgeItem(id: item.id)
        do {
            _ = try await store.fetchItem(id: item.id)
            Issue.record("Expected NotFoundError after purge")
        } catch is NotFoundError { }
    }

    // MARK: - Edge CRUD

    @Test("createEdge and fetchEdgesFromSource") func createEdgeAndFetchEdgesFromSource() async throws {
        let store = try makeStore()
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
        let store = try makeStore()
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
        let store = try makeStore()
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
        let store = try makeStore()
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
        let store = try makeStore()
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
        let store = try makeStore()
        let meta = try await store.fetchMetadata(itemId: "ghost")
        #expect(meta.tags.isEmpty)
        #expect(meta.extensions.isEmpty)
    }

    @Test("setMetadata replaces tags") func setMetadataReplacesTags() async throws {
        let store = try makeStore()
        let item = try await store.createItem(noteInput())
        _ = try await store.setMetadata(itemId: item.id, input: MetadataInput(tags: ["a", "b"]))
        let meta = try await store.fetchMetadata(itemId: item.id)
        #expect(Set(meta.tags) == ["a", "b"])
    }

    @Test("mergeMetadata unions tags") func mergeMetadataUnionsTags() async throws {
        let store = try makeStore()
        let item = try await store.createItem(noteInput())
        _ = try await store.setMetadata(itemId: item.id, input: MetadataInput(tags: ["a"]))
        _ = try await store.mergeMetadata(itemId: item.id, input: MetadataInput(tags: ["b", "c"]))
        let meta = try await store.fetchMetadata(itemId: item.id)
        #expect(Set(meta.tags) == ["a", "b", "c"])
    }

    @Test("addTags unions with existing") func addTagsUnionsWithExisting() async throws {
        let store = try makeStore()
        let item = try await store.createItem(noteInput())
        _ = try await store.addTags(itemId: item.id, tags: ["x"])
        _ = try await store.addTags(itemId: item.id, tags: ["y", "x"])
        let meta = try await store.fetchMetadata(itemId: item.id)
        #expect(Set(meta.tags) == ["x", "y"])
    }

    @Test("removeTag removes single tag") func removeTagRemovesSingleTag() async throws {
        let store = try makeStore()
        let item = try await store.createItem(noteInput())
        _ = try await store.setMetadata(itemId: item.id, input: MetadataInput(tags: ["a", "b", "c"]))
        try await store.removeTag(itemId: item.id, tag: "b")
        let meta = try await store.fetchMetadata(itemId: item.id)
        #expect(Set(meta.tags) == ["a", "c"])
    }

    // MARK: - Pure-local mode via MymeClient.local(path:)

    @Suite("Pure-local client (MymeClient.local)")
    struct PureLocalClientTests {

        private func client() throws -> MymeClient { try MymeClient.local(path: ":memory:") }

        @Test("create and get item") func createAndGet() async throws {
            let client = try client()
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
            let client = try client()
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
            let client = try client()
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
            let client = try client()
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
            let client = try client()
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
            let client = try client()
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
            let client = try client()
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
            let client = try client()
            do {
                _ = try await client.items.get(id: "does-not-exist")
                Issue.record("Expected NotFoundError")
            } catch let e as NotFoundError {
                #expect(e.status == 404)
            }
        }
    }
}
