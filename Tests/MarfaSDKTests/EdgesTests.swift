import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

@Suite("EdgesNamespace")
struct EdgesTests {

    func makeClient() -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let client = MarfaClient(configuration: config, transport: mock)
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
            spaceId: nil,
            targetId: targetId,
            updatedAt: "2026-04-15T00:00:00Z",
            version: 1
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
        // A network-only client names no id, and the key has to be absent
        // rather than null: the route's `id` is optional, which admits a
        // missing key and refuses an explicit null.
        #expect(bodyJSON?.keys.contains("id") == false)
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

        _ = try await client.items.edges(id: "item-1", edgeType: "references", limit: 10)

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

    // MARK: - listToTargets (remote)

    @Test("listToTargets with empty input returns empty dict and makes no calls")
    func listToTargetsEmpty() async throws {
        let (client, mock) = makeClient()

        let result = try await client.edges.listToTargets(targetIds: [])

        #expect(result.isEmpty)
        #expect(mock.calls.isEmpty)
    }

    @Test("listToTargets fans out one call per distinct target")
    func listToTargetsFanOut() async throws {
        let (client, mock) = makeClient()
        // Three identical empty responses — the tasks drain them concurrently
        // and MockTransport hands them out in FIFO order regardless of path.
        for _ in 0..<3 {
            mock.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))
        }

        let result = try await client.edges.listToTargets(
            targetIds: ["t1", "t2", "t3"],
            edgeType: "in-thread"
        )

        #expect(Set(result.keys) == ["t1", "t2", "t3"])
        #expect(result.values.allSatisfy { $0.isEmpty })
        #expect(mock.calls.count == 3)
        #expect(mock.calls.allSatisfy { $0.method == .get })
        let paths = Set(mock.calls.map(\.path))
        #expect(paths == [
            "/items/t1/backrefs",
            "/items/t2/backrefs",
            "/items/t3/backrefs",
        ])
        // Every fan-out call carries the edgeType query parameter.
        #expect(mock.calls.allSatisfy { call in
            call.query?.contains(where: { $0.0 == "edge_type" && $0.1 == "in-thread" }) == true
        })
    }

    @Test("listToTargets keys each response to its request target id")
    func listToTargetsKeying() async throws {
        let (client, mock) = makeClient()
        // Single target → response-to-request mapping is deterministic.
        mock.enqueue(PaginatedResult<Edge>(
            data: [sampleEdge(id: "e1", targetId: "solo")],
            cursor: nil, hasMore: false
        ))

        let result = try await client.edges.listToTargets(targetIds: ["solo"])

        #expect(result["solo"]?.count == 1)
        #expect(result["solo"]?.first?.id == "e1")
    }

    @Test("listToTargets collapses duplicate target IDs")
    func listToTargetsDedup() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))
        mock.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))

        let result = try await client.edges.listToTargets(targetIds: ["a", "a", "b"])

        #expect(Set(result.keys) == ["a", "b"])
        #expect(mock.calls.count == 2)
    }

    @Test("listToTargets propagates a per-target transport error")
    func listToTargetsError() async throws {
        let (client, mock) = makeClient()
        mock.enqueueError(URLError(.timedOut))
        mock.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))

        await #expect(throws: URLError.self) {
            _ = try await client.edges.listToTargets(targetIds: ["t1", "t2"])
        }
    }

    @Test("listToTargets passes per-target limit on each fan-out call")
    func listToTargetsLimit() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))

        _ = try await client.edges.listToTargets(targetIds: ["only"], limit: 25)

        #expect(mock.calls[0].query?.contains(where: { $0.0 == "limit" && $0.1 == "25" }) == true)
    }
}

private extension String {
    /// Small helper for readable path assertions in tests.
    func prepending(_ prefix: String) -> String { prefix + self }
}
