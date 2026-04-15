import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

@Suite("EdgesNamespace")
struct EdgesTests {

    func makeClient() -> (MymeClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let client = MymeClient(configuration: config, transport: mock)
        return (client, mock)
    }

    func sampleEdge(
        id: String = "edge-1",
        sourceId: String = "item-src",
        targetId: String = "item-tgt",
        edgeType: String = "about",
        properties: [String: JSONValue] = [:]
    ) -> Edge {
        Edge(
            createdAt: "2026-04-15T00:00:00Z",
            edgeType: edgeType,
            id: id,
            properties: properties,
            sourceId: sourceId,
            targetId: targetId,
            tenantId: nil,
            updatedAt: "2026-04-15T00:00:00Z"
        )
    }

    // MARK: - create

    @Test("create sends POST /edges with source/target/edge_type in body")
    func create() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(["edge": sampleEdge()])

        let edge = try await client.edges.create(
            source: "item-src",
            target: "item-tgt",
            edgeType: "about",
            properties: ["note": .string("hello")]
        )

        #expect(edge.id == "edge-1")
        #expect(edge.edgeType == "about")
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/edges")

        // Body should be snake_case on the wire.
        let bodyJSON = try JSONSerialization.jsonObject(with: mock.calls[0].body!) as? [String: Any]
        #expect(bodyJSON?["source_id"] as? String == "item-src")
        #expect(bodyJSON?["target_id"] as? String == "item-tgt")
        #expect(bodyJSON?["edge_type"] as? String == "about")
        let props = bodyJSON?["properties"] as? [String: Any]
        #expect(props?["note"] as? String == "hello")
    }

    @Test("create without properties omits the key")
    func createOmitsNilProperties() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(["edge": sampleEdge()])

        _ = try await client.edges.create(
            source: "a", target: "b", edgeType: "about"
        )

        let bodyJSON = try JSONSerialization.jsonObject(with: mock.calls[0].body!) as? [String: Any]
        #expect(bodyJSON?["properties"] == nil)
    }

    // MARK: - update

    @Test("update sends PATCH /edges/:id with only properties")
    func update() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(["edge": sampleEdge(properties: ["note": .string("updated")])])

        let edge = try await client.edges.update(
            id: "edge-1",
            properties: ["note": .string("updated")]
        )

        #expect(edge.id == "edge-1")
        #expect(mock.calls[0].method == .patch)
        #expect(mock.calls[0].path == "/edges/edge-1")

        let bodyJSON = try JSONSerialization.jsonObject(with: mock.calls[0].body!) as? [String: Any]
        #expect(bodyJSON?.keys.sorted() == ["properties"])
    }

    // MARK: - delete

    @Test("delete sends DELETE /edges/:id")
    func delete() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(EmptyResponse())

        try await client.edges.delete(id: "edge-9")

        #expect(mock.calls[0].method == .delete)
        #expect(mock.calls[0].path == "/edges/edge-9")
    }

    // MARK: - listFromSource / listToTarget

    @Test("listFromSource sends GET /items/:id/edges with optional edge_type")
    func listFromSource() async throws {
        let (client, mock) = makeClient()
        let page = PaginatedResult<Edge>(data: [sampleEdge()], cursor: "c1", hasMore: false)
        mock.enqueue(page)

        let result = try await client.edges.listFromSource(
            sourceId: "item-src",
            edgeType: "about",
            cursor: nil,
            limit: 50
        )

        #expect(result.data.count == 1)
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/items/item-src/edges")
        #expect(mock.calls[0].query?.contains(where: { $0.0 == "edge_type" && $0.1 == "about" }) == true)
        #expect(mock.calls[0].query?.contains(where: { $0.0 == "limit" && $0.1 == "50" }) == true)
    }

    @Test("listFromSource with no filters sends no query string")
    func listFromSourceNoQuery() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))

        _ = try await client.edges.listFromSource(sourceId: "x")

        #expect(mock.calls[0].query == nil)
    }

    @Test("listToTarget sends GET /items/:id/backrefs")
    func listToTarget() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(PaginatedResult<Edge>(data: [sampleEdge()], cursor: nil, hasMore: false))

        _ = try await client.edges.listToTarget(
            targetId: "thread-1",
            edgeType: "in-thread"
        )

        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/items/thread-1/backrefs")
        #expect(mock.calls[0].query?.contains(where: { $0.0 == "edge_type" && $0.1 == "in-thread" }) == true)
    }

    // MARK: - items.edges / items.backrefs

    @Test("items.edges proxies GET /items/:id/edges")
    func itemsEdges() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(PaginatedResult<Edge>(data: [sampleEdge()], cursor: nil, hasMore: false))

        _ = try await client.items.edges(id: "item-1", edgeType: "annotates", limit: 10)

        #expect(mock.calls[0].path == "/item-1/edges".prepending("/items"))
        #expect(mock.calls[0].query?.contains(where: { $0.0 == "edge_type" }) == true)
    }

    @Test("items.backrefs proxies GET /items/:id/backrefs")
    func itemsBackrefs() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(PaginatedResult<Edge>(data: [sampleEdge()], cursor: nil, hasMore: false))

        _ = try await client.items.backrefs(id: "item-1")

        #expect(mock.calls[0].path == "/items/item-1/backrefs")
        #expect(mock.calls[0].query == nil)
    }
}

private extension String {
    /// Small helper for readable path assertions in tests.
    func prepending(_ prefix: String) -> String { prefix + self }
}
