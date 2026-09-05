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

    // MARK: - The spellings the server refuses

    /// The regression descent introduced and a review caught: `system` is not
    /// `system.*`.
    ///
    /// The server decides the operational-row exclusion from the **raw**
    /// filter — `type.startsWith("system.")` — so `system` and `system.*` are
    /// different questions to it. Stripping the wildcard makes them one root
    /// here, and a naive descent then answered `system.*`'s question for both,
    /// putting every device, connection and activity row into an ordinary
    /// listing.
    @Test("a bare system namespace does not return operational rows")
    func bareSystemNamespaceIsNotASystemTarget() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        _ = try await client.items.create(
            CreateItemInput(type: "system.connection", properties: [
                "kind": .string("app"), "status": .string("active"),
                "granted_at": .string("2026-09-05T00:00:00.000Z"),
            ])
        )

        let bare = try await client.items.list(filters: ListFilters(type: "system"))
        #expect(bare.data.isEmpty)

        // The discriminator: naming a system type outright still works, so the
        // assertion above is about the spelling rather than about system rows
        // having become unreachable.
        let named = try await client.items.list(filters: ListFilters(type: "system.connection"))
        #expect(named.data.map(\.type) == ["system.connection"])
    }

    @Test("a bare system namespace does not leak into search either")
    func bareSystemNamespaceIsNotASystemTargetInSearch() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        _ = try await client.items.create(
            CreateItemInput(type: "system.connection", properties: [
                "kind": .string("app"), "status": .string("active"),
                "granted_at": .string("2026-09-05T00:00:00.000Z"),
                "title": .string("findme"),
            ])
        )
        let found = try await client.search(query: "findme", filters: SearchFilters(type: "system"))
        #expect(found.isEmpty)
    }

    /// `GET /items` refuses `?type=*` outright: everything is a listing with
    /// no type at all, and a filter matching every type would slip past the
    /// per-type enforcement levers keyed off the parameter.
    ///
    /// A device cannot answer `400` from inside a fetch descriptor, so an
    /// unresolvable spelling resolves to a subtree nothing is in. **The
    /// direction is the point**: showing too little is recoverable by the
    /// caller noticing, and showing everything is not.
    @Test("a wildcard the server refuses matches nothing rather than everything")
    func unresolvableSpellingsFailClosed() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        _ = try await client.items.create(
            CreateItemInput(type: "core.note", properties: ["body": .string("here")])
        )

        for spelling in ["*", "*.*", ".*", "core.note."] {
            let listed = try await client.items.list(filters: ListFilters(type: spelling))
            #expect(listed.data.isEmpty, "\(spelling) should narrow to nothing")
        }

        // And an absent filter still returns the row, so the loop above is not
        // passing because the store is empty.
        let all = try await client.items.list(filters: nil)
        #expect(all.data.map(\.type) == ["core.note"])
    }
}
