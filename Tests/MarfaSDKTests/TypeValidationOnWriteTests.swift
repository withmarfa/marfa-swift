import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// A write the type forbids is refused before it is queued, with no network.
///
/// The server has always refused these. What it could not do is refuse them
/// at the moment the person made one: a write queued offline and refused on
/// reconnect fails hours later, to nobody, in a log.
@Suite("A forbidden write is refused before it is queued", .timeLimit(.minutes(1)))
struct TypeValidationOnWriteTests {

    @Test("a required field the type names must be present")
    func requiredFieldIsEnforcedOffline() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()

        await #expect(throws: TypeValidationError.self) {
            _ = try await client.items.create(
                CreateItemInput(type: "core.note", properties: ["title": .string("no body")])
            )
        }

        // Nothing was written. A refusal that leaves a ghost behind is worse
        // than no refusal, because the row then exists only on this device.
        let listed = try await client.items.list(filters: ListFilters(type: "core.note"))
        #expect(listed.data.isEmpty)
    }

    /// The discriminator: the same write with the field present is accepted,
    /// so the red above is the requirement rather than creates being broken.
    @Test("the same write with the field present is accepted")
    func validWriteProceeds() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let created = try await client.items.create(
            CreateItemInput(type: "core.note", properties: ["body": .string("here")])
        )
        #expect(created.type == "core.note")
    }

    @Test("a declared field holding the wrong type is refused")
    func wrongTypeIsRefused() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        await #expect(throws: TypeValidationError.self) {
            _ = try await client.items.create(
                CreateItemInput(type: "core.note", properties: ["body": .int(3)])
            )
        }
    }

    /// Deliberate, and the reason matters more than the behavior: a space's
    /// own types reach the device through a cache that may never have been
    /// filled, and refusing every custom type until then would make the
    /// offline story worse than no validation at all.
    @Test("an unknown type is not refused locally")
    func unknownTypePasses() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let created = try await client.items.create(
            CreateItemInput(type: "myapp.invoice", properties: ["total": .int(10)])
        )
        #expect(created.type == "myapp.invoice")
    }

    // MARK: - The cache

    private func schema(
        id: String, parent: String? = nil, required: String
    ) -> TypeSchema {
        TypeSchema(
            compatibleWith: nil, description: nil, displayHints: nil,
            fields: [required: .dictionary([
                "type": .string("string"),
                "required": .bool(true),
            ])],
            id: id, label: nil, mergePolicy: nil, parent: parent,
            roles: nil, version: 1, versionPolicy: nil
        )
    }

    @Test("a cached custom type is as enforceable as a shipped one")
    func cachedCustomTypeIsEnforced() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let store = try #require(client.localStore)

        // Before the cache is filled, the type is unknown and passes.
        _ = try await client.items.create(
            CreateItemInput(type: "myapp.invoice", properties: [:])
        )

        try await store.replaceCachedTypes(with: [schema(id: "myapp.invoice", required: "total")])

        await #expect(throws: TypeValidationError.self) {
            _ = try await client.items.create(
                CreateItemInput(type: "myapp.invoice", properties: [:])
            )
        }
        _ = try await client.items.create(
            CreateItemInput(type: "myapp.invoice", properties: ["total": .string("10")])
        )
    }

    /// A refresh replaces the graph rather than merging into it, because
    /// `GET /types` answers with the whole space and a type deleted upstream
    /// is *absent* rather than marked. Merging would keep it for ever, and a
    /// validator holding a type the space no longer has refuses writes the
    /// server would accept.
    @Test("a type the server has dropped stops being cached")
    func refreshReplacesRatherThanMerges() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let store = try #require(client.localStore)

        try await store.replaceCachedTypes(with: [
            schema(id: "myapp.invoice", required: "total"),
            schema(id: "myapp.receipt", required: "amount"),
        ])
        #expect(try await store.cachedTypeDefinitions().count == 2)

        try await store.replaceCachedTypes(with: [schema(id: "myapp.invoice", required: "total")])
        let after = try await store.cachedTypeDefinitions()
        #expect(after.keys.sorted() == ["myapp.invoice"])
    }

    @Test("a cached type's parent chain resolves for descent")
    func cachedParentResolves() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let store = try #require(client.localStore)
        try await store.replaceCachedTypes(with: [
            schema(id: "myapp.invoice", parent: "core.note", required: "total"),
        ])

        let registry = try await client.typeRegistry()
        #expect(registry.isDescendant("myapp.invoice", of: "core.note"))
        #expect(registry.typesAssignable(to: "core.note").contains("myapp.invoice"))
    }
}
