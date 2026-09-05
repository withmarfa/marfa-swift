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

        let thrown = await #expect(throws: TypeValidationError.self) {
            _ = try await client.items.create(
                CreateItemInput(type: "core.note", properties: ["title": .string("no body")])
            )
        }
        // Which field, not just "something threw". Without this the test stays
        // green against a build that refuses every write for its own reasons.
        #expect(thrown?.failures.map(\.field) == ["body"])

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
        let thrown = await #expect(throws: TypeValidationError.self) {
            _ = try await client.items.create(
                CreateItemInput(type: "core.note", properties: ["body": .int(3)])
            )
        }
        #expect(thrown?.failures.map(\.field) == ["body"])
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

    // MARK: - Resolution

    /// `GET /types` answers with schemas **as declared**, so a cached type
    /// carries its own fields and a `parent` id and nothing inherited. A
    /// validator that took that at face value would enforce none of the
    /// parent's rules — the graph would look right and check almost nothing.
    @Test("a custom type inherits its parent's required fields")
    func cachedChildInheritsParentRequirements() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let store = try #require(client.localStore)
        try await store.replaceCachedTypes(with: [
            schema(id: "myapp.invoice", parent: "core.note", required: "total")
        ])

        // `total` is present and `body` — inherited from `core.note` — is not.
        let thrown = await #expect(throws: TypeValidationError.self) {
            _ = try await client.items.create(
                CreateItemInput(type: "myapp.invoice", properties: ["total": .string("10")])
            )
        }
        #expect(thrown?.failures.map(\.field) == ["body"])

        _ = try await client.items.create(
            CreateItemInput(
                type: "myapp.invoice",
                properties: ["total": .string("10"), "body": .string("for services")]
            )
        )
    }

    /// The regression a cache can cause rather than fix. A refresh caches
    /// every type the space can see, core ones included, and the cached copy
    /// wins the merge — so an unresolved `core.note` would replace the
    /// generated, already-flattened one and take the universal fields with it.
    @Test("caching a platform type does not un-resolve it")
    func cachingAPlatformTypeKeepsItsUniversalFields() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let store = try #require(client.localStore)

        let before = try await client.typeRegistry()
        #expect(before.definition(for: "core.note")?.fields["attachments"] != nil)

        // What `GET /types` sends for `core.note`: its own fields, nothing
        // universal, nothing inherited.
        try await store.replaceCachedTypes(with: [
            TypeSchema(
                compatibleWith: nil, description: nil, displayHints: nil,
                fields: ["body": .dictionary([
                    "type": .string("string"), "required": .bool(true),
                ])],
                id: "core.note", label: nil, mergePolicy: nil, parent: nil,
                roles: nil, version: 1, versionPolicy: nil
            )
        ])

        let after = try await client.typeRegistry()
        #expect(after.definition(for: "core.note")?.fields["attachments"] != nil)
    }

    // MARK: - The other write door

    /// `update` is a patch and the server validates the **merge**, so this
    /// asserts on both directions: a patch that empties a required field is
    /// refused, and a patch that simply omits one is not.
    @Test("an update that empties a required field is refused")
    func updateIsValidatedAgainstTheMerge() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let created = try await client.items.create(
            CreateItemInput(type: "core.note", properties: [
                "body": .string("here"), "title": .string("a note"),
            ])
        )

        let thrown = await #expect(throws: TypeValidationError.self) {
            _ = try await client.items.update(id: created.id, properties: ["body": .int(3)])
        }
        #expect(thrown?.failures.map(\.field) == ["body"])

        // A patch touching something else must still go through: validating
        // the patch rather than the merge would refuse this, and refusing it
        // would make almost every edit fail.
        let edited = try await client.items.update(
            id: created.id, properties: ["title": .string("renamed")]
        )
        #expect(edited.properties["title"]?.stringValue == "renamed")
    }

    // MARK: - The wire

    /// Three field constraints the decoder reads, and nothing else reaches.
    ///
    /// **The spelling is the point.** `enum_values` is snake_case while
    /// `maxLength` and `maxItems` are camelCase, on the same object — which
    /// reads like a defect and is not: the server's own `FieldDefinition`
    /// declares them exactly that way. A test that only ever sends `type` and
    /// `required`, as the rest of this suite does, cannot tell a right
    /// spelling from a wrong one.
    @Test("the decoder reads enum values and both bounds, at the server's spelling")
    func wireConstraintsAreDecoded() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let store = try #require(client.localStore)
        try await store.replaceCachedTypes(with: [
            TypeSchema(
                compatibleWith: nil, description: nil, displayHints: nil,
                fields: [
                    // `enum`, not `string`. The server applies `enum_values`
                    // only under a declared `enum` type — a string field
                    // carrying them gets a plain bounded string and the values
                    // are not enforced. Writing this test the obvious way
                    // asserted a rule the server does not have.
                    "status": .dictionary([
                        "type": .string("enum"),
                        "enum_values": .array([.string("open"), .string("closed")]),
                    ]),
                    "code": .dictionary([
                        "type": .string("string"), "maxLength": .int(3),
                    ]),
                    "labels": .dictionary([
                        "type": .string("array"), "maxItems": .int(2),
                    ]),
                ],
                id: "myapp.ticket", label: nil, mergePolicy: nil, parent: nil,
                roles: nil, version: 1, versionPolicy: nil
            )
        ])

        let field = try await client.typeRegistry().definition(for: "myapp.ticket")?.fields
        #expect(field?["status"]?.enumValues == ["open", "closed"])
        #expect(field?["code"]?.maxLength == 3)
        #expect(field?["labels"]?.maxItems == 2)

        // And each one refuses through the validator, so the decode is wired
        // rather than merely parsed.
        await #expect(throws: TypeValidationError.self) {
            _ = try await client.items.create(
                CreateItemInput(type: "myapp.ticket", properties: ["status": .string("wontfix")])
            )
        }
        await #expect(throws: TypeValidationError.self) {
            _ = try await client.items.create(
                CreateItemInput(type: "myapp.ticket", properties: ["code": .string("toolong")])
            )
        }
        await #expect(throws: TypeValidationError.self) {
            _ = try await client.items.create(
                CreateItemInput(type: "myapp.ticket", properties: [
                    "labels": .array([.string("a"), .string("b"), .string("c")]),
                ])
            )
        }
    }
}
