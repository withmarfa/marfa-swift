import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// A query naming a parent type finds the rows stored under its subtypes.
///
/// The server has always answered this way: `?type=core.entity` returns
/// `core.entity.person` too, and it resolves the subtree as a *union* of two
/// things — everything under the dotted name, plus everything that declares
/// its way there. A device that matched the name literally therefore gave a
/// short answer with no error, on a filter the caller had every reason to
/// think it understood.
@Suite("A query by parent type finds its subtypes", .timeLimit(.minutes(1)))
struct LocalSubtypeQueryTests {

    private func person(_ name: String) -> CreateItemInput {
        CreateItemInput(type: "core.entity.person", properties: ["name": .string(name)])
    }

    @Test("listing a parent type returns rows stored under a child type")
    func listByParentFindsChildren() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        _ = try await client.items.create(person("Ada"))
        _ = try await client.items.create(
            CreateItemInput(type: "core.entity", properties: ["name": .string("Acme")])
        )
        _ = try await client.items.create(
            CreateItemInput(type: "core.note", properties: ["body": .string("unrelated")])
        )

        let listed = try await client.items.list(filters: ListFilters(type: "core.entity"))
        #expect(Set(listed.data.map(\.type)) == ["core.entity", "core.entity.person"])
    }

    /// The discriminator for the test above: descent must not become "match
    /// everything". A sibling namespace sharing a prefix is the case a naive
    /// `starts(with:)` gets wrong.
    @Test("descent stops at a dot, so a sibling sharing a prefix is excluded")
    func descentDoesNotLeakAcrossASharedPrefix() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        _ = try await client.items.create(
            CreateItemInput(type: "core.note", properties: ["body": .string("kept")])
        )
        _ = try await client.items.create(
            CreateItemInput(type: "core.notebook", properties: ["body": .string("excluded")])
        )

        let listed = try await client.items.list(filters: ListFilters(type: "core.note"))
        #expect(listed.data.map(\.type) == ["core.note"])
    }

    /// The half a namespace walk cannot reach. Registration has never required
    /// a child's identifier to start with its parent's, so a type may declare
    /// `core.note` as its parent while being named under `user`. The server
    /// resolves it; before this, the device did not.
    @Test("a child declaring its parent from another namespace is found")
    func declaredChildOutsideTheNamespaceIsFound() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let store = try #require(client.localStore)
        try await store.replaceCachedTypes(with: [
            TypeSchema(
                compatibleWith: nil, description: nil, displayHints: nil,
                fields: ["body": .dictionary(["type": .string("string"), "required": .bool(true)])],
                id: "user.annotated_note", label: nil, mergePolicy: nil,
                parent: "core.note", roles: nil, version: 1, versionPolicy: nil
            )
        ])

        _ = try await client.items.create(
            CreateItemInput(type: "user.annotated_note", properties: ["body": .string("annotated")])
        )
        _ = try await client.items.create(
            CreateItemInput(type: "core.note", properties: ["body": .string("plain")])
        )

        let listed = try await client.items.list(filters: ListFilters(type: "core.note"))
        #expect(Set(listed.data.map(\.type)) == ["core.note", "user.annotated_note"])
    }

    /// Search applies the same subtree rule, because the server applies it in
    /// exactly these two places and nowhere else.
    ///
    /// The fixture is a `core.note` subtype rather than a `core.entity` one on
    /// purpose: offline search matches over `title` and `body` alone, so an
    /// entity keying its text in `name` would fail this for a reason that has
    /// nothing to do with subtrees.
    @Test("offline search narrows by subtree too")
    func searchByParentFindsChildren() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let store = try #require(client.localStore)
        try await store.replaceCachedTypes(with: [
            TypeSchema(
                compatibleWith: nil, description: nil, displayHints: nil,
                fields: ["body": .dictionary(["type": .string("string")])],
                id: "core.note.annotated", label: nil, mergePolicy: nil,
                parent: "core.note", roles: nil, version: 1, versionPolicy: nil
            )
        ])
        _ = try await client.items.create(
            CreateItemInput(
                type: "core.note.annotated", properties: ["body": .string("Ada wrote this")]
            )
        )
        _ = try await client.items.create(
            CreateItemInput(type: "core.entity", properties: ["name": .string("Ada")])
        )

        let found = try await client.search(
            query: "Ada", filters: SearchFilters(type: "core.note")
        )
        #expect(found.map(\.item.type) == ["core.note.annotated"])
    }

    /// The wildcard spelling the server accepts as a synonym.
    @Test("the explicit wildcard spelling means the same subtree")
    func wildcardSpellingIsASynonym() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        _ = try await client.items.create(person("Ada"))

        let listed = try await client.items.list(filters: ListFilters(type: "core.entity.*"))
        #expect(listed.data.map(\.type) == ["core.entity.person"])
    }
}
