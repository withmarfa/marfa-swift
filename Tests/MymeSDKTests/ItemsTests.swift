import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

@Suite("ItemsNamespace")
struct ItemsTests {

    func makeClient() -> (MymeClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let client = MymeClient(configuration: config, transport: mock)
        return (client, mock)
    }

    func sampleItem() -> ItemResponse {
        ItemResponse(
            item: Item(
                createdAt: "2026-01-01T00:00:00Z",
                id: "test-id",
                library: false,
                origin: .user,
                properties: ["title": .string("Test Note")],
                schemaVersion: 1,
                source: "sdk-test",
                state: .active,
                timestamp: "2026-01-01T00:00:00Z",
                type: "core.note",
                updatedAt: "2026-01-01T00:00:00Z",
                version: 1
            ),
            metadata: Metadata(
                extensions: [:],
                itemId: "test-id",
                tags: ["test"]
            )
        )
    }

    @Test("Create item sends POST /items")
    func createItem() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(sampleItem())

        let input = CreateItemInput(
            type: "core.note",
            properties: ["title": .string("Test Note")]
        )
        let item = try await client.items.create(input)

        #expect(item.id == "test-id")
        #expect(item.type == "core.note")
        #expect(item.state == .active)
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/items")
    }

    @Test("Get item sends GET /items/:id")
    func getItem() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(sampleItem())

        let item = try await client.items.get(id: "test-id")

        #expect(item.id == "test-id")
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/items/test-id")
    }

    @Test("List items sends GET /items with query params")
    func listItems() async throws {
        let (client, mock) = makeClient()
        let page = PaginatedResult<Item>(data: [sampleItem().item], cursor: nil, hasMore: false)
        mock.enqueue(page)

        let result = try await client.items.list(filters: ListFilters(type: "core.note", limit: 10))

        #expect(result.data.count == 1)
        #expect(result.hasMore == false)
        #expect(mock.calls[0].query?.contains(where: { $0.0 == "type" && $0.1 == "core.note" }) == true)
        #expect(mock.calls[0].query?.contains(where: { $0.0 == "limit" && $0.1 == "10" }) == true)
    }

    @Test("Delete item sends DELETE /items/:id")
    func deleteItem() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(EmptyResponse())

        try await client.items.delete(id: "test-id")

        #expect(mock.calls[0].method == .delete)
        #expect(mock.calls[0].path == "/items/test-id")
    }

    @Test("Transition sends POST /items/:id/transition")
    func transitionItem() async throws {
        let (client, mock) = makeClient()
        var response = sampleItem()
        response.item = Item(
            createdAt: "2026-01-01T00:00:00Z",
            id: "test-id",
            library: false,
            origin: .user,
            properties: [:],
            schemaVersion: 1,
            source: "sdk-test",
            state: .active,
            timestamp: "2026-01-01T00:00:00Z",
            type: "core.note",
            updatedAt: "2026-01-01T00:00:00Z",
            version: 1
        )
        mock.enqueue(response)

        let item = try await client.items.transition(id: "test-id", to: "active")

        #expect(item.state == .active)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/items/test-id/transition")
    }

    @Test("Update without version fetches current version first, then patches")
    func updateFetchesVersionWhenUnset() async throws {
        let (client, mock) = makeClient()
        // 1) GET /items/:id to resolve version, 2) PATCH with that version
        mock.enqueue(sampleItem())
        mock.enqueue(sampleItem())

        _ = try await client.items.update(id: "test-id", properties: ["title": .string("Updated")])

        #expect(mock.calls.count == 2)
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/items/test-id")
        #expect(mock.calls[1].method == .patch)
        #expect(mock.calls[1].path == "/items/test-id")
    }

    @Test("Update with explicit version skips the initial GET")
    func updateSkipsFetchWhenVersionProvided() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(sampleItem())

        _ = try await client.items.update(
            id: "test-id",
            properties: ["title": .string("Updated")],
            options: UpdateOptions(version: 4)
        )

        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].method == .patch)
    }

    @Test("Create item with edges emits edges array in snake_case body")
    func createWithEdges() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(sampleItem())

        let input = CreateItemInput(
            type: "core.note",
            properties: ["title": .string("Hello")],
            edges: [
                CreateItemEdge(
                    edgeType: "in-thread",
                    direction: .outbound,
                    otherId: "thread-1",
                    properties: ["position": .double(1)]
                ),
                CreateItemEdge(
                    edgeType: "about",
                    direction: .outbound,
                    otherId: "topic-1"
                ),
            ]
        )
        _ = try await client.items.create(input)

        let body = try JSONSerialization.jsonObject(with: mock.calls[0].body!) as? [String: Any]
        let edges = body?["edges"] as? [[String: Any]]
        #expect(edges?.count == 2)
        #expect(edges?[0]["edge_type"] as? String == "in-thread")
        #expect(edges?[0]["other_id"] as? String == "thread-1")
        #expect(edges?[0]["direction"] as? String == "outbound")
        // parent_id / thread_id / about must be absent on the wire now.
        #expect(body?["parent_id"] == nil)
        #expect(body?["thread_id"] == nil)
        #expect(body?["about"] == nil)
    }

    @Test("Stats sends GET /items/stats")
    func stats() async throws {
        let (client, mock) = makeClient()
        let statsData: [String: Int] = ["new": 5, "active": 10, "archived": 3, "trashed": 1]
        mock.enqueue(statsData)

        let stats = try await client.items.stats()

        #expect(stats["new"] == 5)
        #expect(stats["active"] == 10)
        #expect(mock.calls[0].path == "/items/stats")
    }
}
