import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

@Suite("TypesNamespace")
struct TypesNamespaceTests {

    func makeClient() -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MarfaClient(configuration: config, transport: mock)
        return (client, mock)
    }

    func makeSchema(
        id: String = "demo.foo",
        version: Int = 1,
        parent: String? = "core.note"
    ) -> TypeSchema {
        TypeSchema(
            description: nil,
            displayHints: nil,
            fields: ["body": .dictionary(["type": .string("string")])],
            id: id,
            label: "Demo",
            mergePolicy: nil,
            parent: parent,
            version: version,
            versionPolicy: nil
        )
    }

    @Test("list sends GET /types and returns the array directly")
    func list() async throws {
        let (client, mock) = makeClient()
        mock.enqueue([makeSchema(id: "demo.alpha"), makeSchema(id: "demo.beta")])

        let result = try await client.types.list()

        #expect(result.count == 2)
        #expect(result[0].id == "demo.alpha")
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/types")
    }

    @Test("get sends GET /types/{id}")
    func get() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(makeSchema(id: "demo.foo"))

        let schema = try await client.types.get(id: "demo.foo")

        #expect(schema.id == "demo.foo")
        #expect(mock.calls[0].path == "/types/demo.foo")
    }

    @Test("register sends POST /types and unwraps the type envelope (T-163)")
    func register() async throws {
        let (client, mock) = makeClient()
        // Server returns { "type": ... }; SDK unwraps via TypeResponse.
        struct Envelope: Encodable { let type: TypeSchema }
        mock.enqueue(Envelope(type: makeSchema(id: "demo.foo", version: 1)))

        let result = try await client.types.register(makeSchema(id: "demo.foo", version: 1))

        // The wrapper-vs-cast bug would surface here as a non-populated
        // id or version. Both must come back populated.
        #expect(result.id == "demo.foo")
        #expect(result.version == 1)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/types")
    }

    @Test("update sends PUT /types/{id} and unwraps the type envelope (T-167)")
    func update() async throws {
        let (client, mock) = makeClient()
        struct Envelope: Encodable { let type: TypeSchema }
        mock.enqueue(Envelope(type: makeSchema(id: "demo.foo", version: 2)))

        let result = try await client.types.update(
            id: "demo.foo",
            schema: makeSchema(id: "demo.foo", version: 2)
        )

        #expect(result.id == "demo.foo")
        #expect(result.version == 2)
        #expect(mock.calls[0].method == .put)
        #expect(mock.calls[0].path == "/types/demo.foo")
    }

    @Test("delete sends DELETE /types/{id} without force flag by default")
    func deleteWithoutForce() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(EmptyResponse())

        try await client.types.delete(id: "demo.foo")

        #expect(mock.calls[0].method == .delete)
        #expect(mock.calls[0].path == "/types/demo.foo")
        #expect(mock.calls[0].query == nil || mock.calls[0].query?.isEmpty == true)
    }

    @Test("delete sends ?force=true when forced")
    func deleteWithForce() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(EmptyResponse())

        try await client.types.delete(id: "demo.foo", force: true)

        let query = mock.calls[0].query ?? []
        #expect(query.contains { $0.0 == "force" && $0.1 == "true" })
    }
}
