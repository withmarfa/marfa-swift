import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

@Suite("ThreadsNamespace (edge-backed convenience)")
struct ThreadsTests {

    func makeClient() -> (MymeClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let client = MymeClient(configuration: config, transport: mock)
        return (client, mock)
    }

    func sampleThread(id: String = "thread-1") -> MymeThread {
        MymeThread(
            createdAt: "2026-04-15T00:00:00Z",
            id: id,
            updatedAt: "2026-04-15T00:00:00Z"
        )
    }

    func sampleEdge(
        id: String = "edge-1",
        sourceId: String,
        targetId: String,
        edgeType: String = "in-thread",
        position: Double? = nil
    ) -> Edge {
        var properties: [String: JSONValue] = [:]
        if let position { properties["position"] = .double(position) }
        return Edge(
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

    func sampleItem(id: String) -> ItemResponse {
        ItemResponse(
            item: Item(
                createdAt: "2026-04-15T00:00:00Z",
                id: id,
                library: true,
                origin: .user,
                properties: ["title": .string(id)],
                schemaVersion: 1,
                source: "sdk-test",
                state: .active,
                timestamp: "2026-04-15T00:00:00Z",
                type: "core.note",
                updatedAt: "2026-04-15T00:00:00Z",
                version: 1
            ),
            metadata: nil
        )
    }

    /// Encodable stand-in for the `GET /threads/:id` envelope
    /// (`{ thread, items }`) used by several tests.
    struct ThreadWithItemsPayload: Encodable {
        let thread: MymeThread
        let items: [Item]
    }

    func threadWithItems(threadId: String, itemIds: [String]) -> ThreadWithItemsPayload {
        ThreadWithItemsPayload(
            thread: sampleThread(id: threadId),
            items: itemIds.map { sampleItem(id: $0).item }
        )
    }

    // MARK: - thread records

    /// Envelope for the `{ "thread": MymeThread }` payload used by `POST /threads`.
    struct ThreadEnvelope: Encodable {
        let thread: MymeThread
    }

    @Test("create sends POST /threads")
    func create() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(ThreadEnvelope(thread: sampleThread()))

        let thread = try await client.threads.create()

        #expect(thread.id == "thread-1")
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/threads")
    }

    @Test("get sends GET /threads/:id and returns the thread record")
    func get() async throws {
        let (client, mock) = makeClient()
        // Server returns `{ thread, items }` — SDK returns just `MymeThread` here.
        mock.enqueue(threadWithItems(threadId: "t-9", itemIds: []))

        let thread = try await client.threads.get(id: "t-9")

        #expect(thread.id == "t-9")
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/threads/t-9")
    }

    // MARK: - addMember

    @Test("addMember creates an in-thread edge from item to thread")
    func addMember() async throws {
        let (client, mock) = makeClient()
        let edge = sampleEdge(sourceId: "item-a", targetId: "thread-1", position: 1.0)
        mock.enqueue(["edge": edge])

        let created = try await client.threads.addMember(
            threadId: "thread-1",
            itemId: "item-a",
            position: 1.0
        )

        #expect(created.id == "edge-1")
        #expect(created.sourceId == "item-a")
        #expect(created.targetId == "thread-1")
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/edges")

        let body = try JSONSerialization.jsonObject(with: mock.calls[0].body!) as? [String: Any]
        #expect(body?["source_id"] as? String == "item-a")
        #expect(body?["target_id"] as? String == "thread-1")
        #expect(body?["edge_type"] as? String == "in-thread")
        let props = body?["properties"] as? [String: Any]
        #expect((props?["position"] as? Double) == 1.0)
    }

    @Test("addMember without position sends no properties")
    func addMemberNoPosition() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(["edge": sampleEdge(sourceId: "i", targetId: "t")])

        _ = try await client.threads.addMember(threadId: "t", itemId: "i")

        let body = try JSONSerialization.jsonObject(with: mock.calls[0].body!) as? [String: Any]
        #expect(body?["properties"] == nil)
    }

    // MARK: - removeMember

    @Test("removeMember finds the in-thread edge and deletes it")
    func removeMember() async throws {
        let (client, mock) = makeClient()
        let edge = sampleEdge(id: "edge-42", sourceId: "item-a", targetId: "thread-1")
        mock.enqueue(PaginatedResult<Edge>(data: [edge], cursor: nil, hasMore: false))
        mock.enqueue(EmptyResponse())

        let removed = try await client.threads.removeMember(
            threadId: "thread-1", itemId: "item-a"
        )

        #expect(removed == true)
        #expect(mock.calls.count == 2)
        // First: list outbound edges on item-a.
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/items/item-a/edges")
        #expect(mock.calls[0].query?.contains(where: { $0.0 == "edge_type" && $0.1 == "in-thread" }) == true)
        // Second: delete the matched edge.
        #expect(mock.calls[1].method == .delete)
        #expect(mock.calls[1].path == "/edges/edge-42")
    }

    @Test("removeMember returns false when no matching edge exists")
    func removeMemberMissing() async throws {
        let (client, mock) = makeClient()
        // Outbound edges exist, but none targets this thread.
        mock.enqueue(PaginatedResult<Edge>(
            data: [sampleEdge(sourceId: "item-a", targetId: "thread-other")],
            cursor: nil,
            hasMore: false
        ))

        let removed = try await client.threads.removeMember(
            threadId: "thread-1", itemId: "item-a"
        )

        #expect(removed == false)
        #expect(mock.calls.count == 1) // no delete fired
    }

    // MARK: - getWithMembers / memberItems

    @Test("getWithMembers returns thread + items from one GET /threads/:id call")
    func getWithMembers() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(threadWithItems(threadId: "thread-1", itemIds: ["item-a", "item-b"]))

        let bundle = try await client.threads.getWithMembers(id: "thread-1")

        #expect(bundle.thread.id == "thread-1")
        #expect(bundle.items.map(\.id) == ["item-a", "item-b"])
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].path == "/threads/thread-1")
    }

    @Test("memberItems returns items in server order (one call)")
    func memberItems() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(threadWithItems(threadId: "thread-1", itemIds: ["item-a", "item-b"]))

        let items = try await client.threads.memberItems(id: "thread-1")

        #expect(items.map(\.id) == ["item-a", "item-b"])
        #expect(mock.calls.count == 1)
    }

    // MARK: - setPosition

    @Test("setPosition PATCHes the edge with position in properties")
    func setPosition() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(["edge": sampleEdge(sourceId: "i", targetId: "t", position: 5.0)])

        _ = try await client.threads.setPosition(edgeId: "edge-1", position: 5.0)

        #expect(mock.calls[0].method == .patch)
        #expect(mock.calls[0].path == "/edges/edge-1")
        let body = try JSONSerialization.jsonObject(with: mock.calls[0].body!) as? [String: Any]
        let props = body?["properties"] as? [String: Any]
        #expect((props?["position"] as? Double) == 5.0)
    }
}
