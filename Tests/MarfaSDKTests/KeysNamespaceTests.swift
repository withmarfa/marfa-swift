import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

@Suite("KeysNamespace")
struct KeysNamespaceTests {

    func makeClient() -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MarfaClient(configuration: config, transport: mock)
        return (client, mock)
    }

    func makeCreatedKey(id: String = "key-1", value: String = "marfa_k1_secret") -> CreatedKey {
        CreatedKey(
            createdAt: "2026-05-01T00:00:00Z",
            defaultTier: .library,
            edgePermissions: nil,
            extensionPermissions: nil,
            id: id,
            isOperator: false,
            key: value,
            label: "test-key",
            lastUsedAt: nil,
            metadataPermissions: nil,
            source: "test",
            spacePermissions: [],
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
            isOperator: false,
            label: "key-\(id)",
            lastUsedAt: nil,
            metadataPermissions: nil,
            source: "test",
            spacePermissions: [],
            typePermissions: [:]
        )
    }

    @Test("create POSTs /keys with snake_case body and returns the raw key on the response")
    func create() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(makeCreatedKey(value: "marfa_k1_abc"))

        let result = try await client.keys.create(
            CreateKeyInput(
                label: "test-key",
                source: "test-suite",
                spacePermissions: [.keys, .webhooks],
                typePermissions: ["core.note": .write]
            )
        )

        #expect(result.key == "marfa_k1_abc")
        #expect(result.spacePermissions?.isEmpty ?? true)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/keys")

        // Body is camelCase encoded to snake_case via CodingKeys.
        let body = mock.calls[0].body!
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(json["label"] as? String == "test-key")
        #expect(json["source"] as? String == "test-suite")
        // The dotted literals go over the wire as they are: the Swift case
        // names are camelCase for the compiler's sake and mean nothing to the
        // server, which knows only `space.keys`.
        #expect(
            json["space_permissions"] as? [String] == [
                "space.keys", "space.webhooks",
            ]
        )
        let typePerms = json["type_permissions"] as? [String: String]
        #expect(typePerms?["core.note"] == "write")
    }

    /// The gap that let `keys.create` ship unable to succeed anywhere.
    ///
    /// `RouteCoverageTests` compares paths and methods, so it confirmed
    /// this kit calls `POST /keys` and stopped. **A body is not a route.**
    /// The server required `source`, `CreateKeyInput` could not express
    /// one, and every call was refused — with nothing in this repository
    /// able to see it, because the case above asserted only the fields the
    /// input happened to carry.
    ///
    /// So this reads the requirement from the vendored spec rather than
    /// restating it. A field the platform makes required later fails here
    /// on the next snapshot sync instead of at a caller.
    @Test("the encoded create body carries every field the spec makes required")
    func createBodyCarriesRequiredFields() async throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: packageRoot.appendingPathComponent("scripts/openapi.json"))
        let spec = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let schema = try #require(
            (((((spec["paths"] as? [String: Any])?["/keys"] as? [String: Any])?[
                "post"] as? [String: Any])?["requestBody"] as? [String: Any])?[
                    "content"] as? [String: Any])?["application/json"]
                as? [String: Any],
            "the snapshot declares no JSON body for POST /keys")
        let required = try #require(
            (schema["schema"] as? [String: Any])?["required"] as? [String],
            "the snapshot names no required fields for POST /keys")
        // The control. An empty list would make every assertion below
        // vacuous, and this test's whole subject is a check that passed
        // while measuring nothing.
        #expect(!required.isEmpty)

        let (client, mock) = makeClient()
        mock.enqueue(makeCreatedKey())
        _ = try await client.keys.create(
            CreateKeyInput(label: "test-key", source: "test-suite"))

        let body = try #require(mock.calls[0].body)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        for field in required {
            #expect(json[field] != nil, "the create body omits `\(field)`, which the server requires")
        }
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
