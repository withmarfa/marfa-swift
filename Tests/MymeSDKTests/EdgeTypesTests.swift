import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

/// Covers ``EdgeTypesAPI`` — the `client.edges.edgeTypes.create / list / delete`
/// parity surface with the TypeScript SDK's `client.edges.types.*`.
@Suite("EdgeTypesAPI")
struct EdgeTypesTests {

    // MARK: - Helpers

    private func makeClient() -> (MymeClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        return (MymeClient(configuration: config, transport: mock), mock)
    }

    private func sampleEdgeType(id: String = "team.commented-on") -> EdgeType {
        EdgeType(
            cardinality: .manyToMany,
            cascadeOnDelete: .orphan,
            description: "Comment relationship",
            id: id,
            label: "Commented on",
            propertySchema: [:],
            sourceTypeConstraints: ["core.note"],
            targetTypeConstraints: ["core.note"]
        )
    }

    // MARK: - create

    @Test("create sends POST /edges/types with snake_case body")
    func create() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(["edge_type": sampleEdgeType()])

        let input = CreateEdgeTypeInput(
            id: "team.commented-on",
            cardinality: .manyToMany,
            label: "Commented on",
            sourceTypeConstraints: ["core.note"],
            targetTypeConstraints: ["core.note"],
            cascadeOnDelete: .orphan
        )
        let created = try await client.edges.edgeTypes.create(input)

        #expect(created.id == "team.commented-on")
        #expect(created.cardinality == .manyToMany)
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/edges/types")

        // Body must be snake_case'd for source_type_constraints etc.
        let body = try #require(mock.calls[0].body)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(decoded?["id"] as? String == "team.commented-on")
        #expect(decoded?["cardinality"] as? String == "many-to-many")
        #expect(decoded?["source_type_constraints"] as? [String] == ["core.note"])
        #expect(decoded?["target_type_constraints"] as? [String] == ["core.note"])
        #expect(decoded?["cascade_on_delete"] as? String == "orphan")
    }

    // MARK: - list

    @Test("list sends GET /edges/types and unwraps edge_types")
    func list() async throws {
        let (client, mock) = makeClient()
        let a = sampleEdgeType(id: "a.rel")
        let b = sampleEdgeType(id: "b.rel")
        mock.enqueue(["edge_types": [a, b]])

        let types = try await client.edges.edgeTypes.list()

        #expect(types.count == 2)
        #expect(types.map(\.id) == ["a.rel", "b.rel"])
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/edges/types")
    }

    // MARK: - delete

    @Test("delete sends DELETE /edges/types/{id}")
    func delete() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(["ok": true])

        try await client.edges.edgeTypes.delete(id: "team.commented-on")

        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].method == .delete)
        #expect(mock.calls[0].path == "/edges/types/team.commented-on")
    }

    // MARK: - admin gate

    @Test("create surfaces ForbiddenError from a non-admin key")
    func createForbidden() async throws {
        let (client, mock) = makeClient()
        mock.enqueueError(ForbiddenError(message: "admin permission required"))

        let input = CreateEdgeTypeInput(id: "x.rel", cardinality: .oneToMany)
        do {
            _ = try await client.edges.edgeTypes.create(input)
            Issue.record("expected ForbiddenError")
        } catch let error as ForbiddenError {
            #expect(error.status == 403)
        }
    }
}
