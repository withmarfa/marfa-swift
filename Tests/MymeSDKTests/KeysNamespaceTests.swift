import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

@Suite("KeysNamespace")
struct KeysNamespaceTests {

    func makeClient() -> (MymeClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MymeClient(configuration: config, transport: mock)
        return (client, mock)
    }

    func makeCreatedKey(id: String = "key-1", value: String = "myme_k1_secret") -> CreatedKey {
        CreatedKey(
            createdAt: "2026-05-01T00:00:00Z",
            defaultTier: .library,
            edgePermissions: nil,
            extensionPermissions: nil,
            id: id,
            isPlatform: false,
            key: value,
            label: "test-key",
            lastUsedAt: nil,
            metadataPermissions: nil,
            role: .member,
            source: "test",
            typePermissions: ["core.note": .write]
        )
    }

    func makeListedKey(id: String) -> ApiKey {
        ApiKey(
            createdAt: "2026-05-01T00:00:00Z",
            defaultTier: .library,
            edgePermissions: nil,
            extensionPermissions: nil,
            id: id,
            isPlatform: false,
            label: "key-\(id)",
            lastUsedAt: nil,
            metadataPermissions: nil,
            role: .member,
            source: "test",
            typePermissions: [:]
        )
    }

    @Test("create POSTs /keys with snake_case body and returns the raw key on the response")
    func create() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(makeCreatedKey(value: "myme_k1_abc"))

        let result = try await client.keys.create(
            CreateKeyInput(
                label: "test-key",
                role: .member,
                typePermissions: ["core.note": .write]
            )
        )

        #expect(result.key == "myme_k1_abc")
        #expect(result.role == .member)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/keys")

        // Body is camelCase encoded to snake_case via CodingKeys.
        let body = mock.calls[0].body!
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(json["label"] as? String == "test-key")
        #expect(json["role"] as? String == "member")
        let typePerms = json["type_permissions"] as? [String: String]
        #expect(typePerms?["core.note"] == "write")
    }

    @Test("list unwraps the keys envelope into [ApiKey]")
    func list() async throws {
        let (client, mock) = makeClient()
        struct Envelope: Encodable { let keys: [ApiKey] }
        mock.enqueue(Envelope(keys: [
            makeListedKey(id: "key-1"),
            makeListedKey(id: "key-2")
        ]))

        let keys = try await client.keys.list()

        #expect(keys.count == 2)
        #expect(keys[0].id == "key-1")
        #expect(mock.calls[0].path == "/keys")
    }

    @Test("revoke sends DELETE /keys/{id}")
    func revoke() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(EmptyResponse())

        try await client.keys.revoke(id: "key-1")

        #expect(mock.calls[0].method == .delete)
        #expect(mock.calls[0].path == "/keys/key-1")
    }
}
