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
        // A row search CAN see and the subtree must still exclude. The
        // `core.entity` row below is invisible to offline search anyway —
        // it keys its text in `name` — so on its own it discriminates
        // nothing, and this test would have passed against a filter that
        // narrowed by nothing at all.
        _ = try await client.items.create(
            CreateItemInput(type: "core.task", properties: [
                "title": .string("Ada"), "status": .string("todo"),
            ])
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

        // The discriminator its listing sibling already had: naming the type
        // outright still finds the row, so the emptiness above is about the
        // spelling rather than about search being dead for system types.
        let named = try await client.search(
            query: "findme", filters: SearchFilters(type: "system.connection")
        )
        #expect(named.map(\.item.type) == ["system.connection"])
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

        // Two discriminators, and the second is the one that matters. An
        // absent filter proves the store is not empty — but that is an
        // UNTYPED listing, so it stays green if the typed branch matches
        // nothing at all, which is the way this loop can pass for the wrong
        // reason. A real type filter is what rules that out.
        let all = try await client.items.list(filters: nil)
        #expect(all.data.map(\.type) == ["core.note"])
        let typed = try await client.items.list(filters: ListFilters(type: "core.note"))
        #expect(typed.data.map(\.type) == ["core.note"])
    }

    // MARK: - The clauses nothing was watching

    /// The fail-open half of the `system.` rule, and the one a review found
    /// surviving every mutation.
    ///
    /// A declared child named under `system.` whose parent is an ordinary
    /// type is reached by the **captured set**, not by the namespace walk — so
    /// scrubbing the namespace is not enough and the set has to be scrubbed
    /// too. Without it, an ordinary `?type=core.note` hands back an
    /// operational row: the exact leak the `system.` exclusion exists to
    /// prevent, through the one door it was not being checked at.
    @Test("a declared child named under system is kept out of an ordinary listing")
    func declaredSystemChildDoesNotLeakIntoAnOrdinaryListing() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let store = try #require(client.localStore)
        try await store.replaceCachedTypes(with: [
            TypeSchema(
                compatibleWith: nil, description: nil, displayHints: nil,
                fields: ["body": .dictionary(["type": .string("string")])],
                id: "system.leaked_note", label: nil, mergePolicy: nil,
                parent: "core.note", roles: nil, version: 1, versionPolicy: nil
            )
        ])
        _ = try await client.items.create(
            CreateItemInput(type: "system.leaked_note", properties: ["body": .string("hidden")])
        )
        _ = try await client.items.create(
            CreateItemInput(type: "core.note", properties: ["body": .string("ordinary")])
        )

        let listed = try await client.items.list(filters: ListFilters(type: "core.note"))
        #expect(listed.data.map(\.type) == ["core.note"])
    }

    /// The other side of the same rule: naming a system type outright opts in,
    /// so its declared children come back rather than being scrubbed away.
    ///
    /// Forcing the opt-in off reddened nothing before this, so the branch that
    /// *keeps* declared system children was unverified in both directions.
    @Test("naming a system type outright returns its declared children")
    func namingASystemTypeKeepsItsDeclaredChildren() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let store = try #require(client.localStore)
        try await store.replaceCachedTypes(with: [
            TypeSchema(
                compatibleWith: nil, description: nil, displayHints: nil,
                fields: ["status": .dictionary([
                    "type": .string("enum"),
                    "enum_values": .array([.string("active"), .string("revoked")]),
                ])],
                id: "vendor.link", label: nil, mergePolicy: nil,
                parent: "system.connection", roles: nil, version: 1, versionPolicy: nil
            )
        ])
        _ = try await client.items.create(
            CreateItemInput(type: "vendor.link", properties: [
                "status": .string("active"), "kind": .string("app"),
                "granted_at": .string("2026-09-05T00:00:00.000Z"),
            ])
        )
        _ = try await client.items.create(
            CreateItemInput(type: "system.connection", properties: [
                "kind": .string("app"), "status": .string("active"),
                "granted_at": .string("2026-09-05T00:00:00.000Z"),
            ])
        )

        let listed = try await client.items.list(filters: ListFilters(type: "system.connection"))
        #expect(Set(listed.data.map(\.type)) == ["system.connection", "vendor.link"])
    }

    /// A subtree filter combined with `tags` takes the unwindowed path, which
    /// resolves the filter through a different branch of `itemModels`. Nothing
    /// exercised the two together, so dropping the type filter on that path
    /// changed no test.
    @Test("a subtree filter still narrows on the tag-filtered path")
    func subtreeNarrowsOnTheUnwindowedPath() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let person = try await client.items.create(person("Ada"))
        let note = try await client.items.create(
            CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        )
        try await client.metadata.addTags(itemId: person.id, tags: ["shared"])
        try await client.metadata.addTags(itemId: note.id, tags: ["shared"])

        var filters = ListFilters(type: "core.entity")
        filters.tags = ["shared"]
        let listed = try await client.items.list(filters: filters)
        #expect(listed.data.map(\.type) == ["core.entity.person"])
    }
}

/// The descent walk on its own, over a plain parent map.
///
/// It is `static` and takes `[String: String]`, so these need no store and no
/// client — and both cases below survived every mutation the behavioural
/// tests could apply, because neither shape had a fixture anywhere.
@Suite("Declared descent over a bare parent map", .timeLimit(.minutes(1)))
struct DeclaredDescentTests {

    private func descendants(of root: String, _ parents: [String: String]) -> Set<String> {
        MarfaTypeRegistry.declaredDescendantsOutsideNamespace(of: root, parents: parents)
    }

    /// Transitive, not one level. A cached type whose parent is itself a
    /// cached type is the ordinary shape once a space has more than a couple
    /// of its own types, and a single-level check passed every existing test.
    @Test("descent reaches a grandchild, not only a child")
    func descentIsTransitive() {
        let parents = [
            "vendor.invoice": "core.note",
            "vendor.invoice_line": "vendor.invoice",
            "vendor.unrelated": "core.task",
        ]
        #expect(descendants(of: "core.note", parents) == ["vendor.invoice", "vendor.invoice_line"])
    }

    /// A graph assembled from a server's own types can hold a cycle, and a
    /// walk that trusted it to terminate would hang the caller rather than
    /// answer. Terminating is the assertion; the answer it gives is
    /// secondary.
    @Test("a cycle terminates rather than hanging or reporting a false positive")
    func cycleTerminates() {
        let parents = ["a.one": "a.two", "a.two": "a.one"]
        #expect(descendants(of: "core.note", parents).isEmpty)

        // And a cycle hanging off a real root still answers for the part that
        // does resolve, rather than the whole walk being abandoned.
        let mixed = [
            "a.one": "a.two", "a.two": "a.one",
            "vendor.real": "core.note",
        ]
        #expect(descendants(of: "core.note", mixed) == ["vendor.real"])
    }

    /// Names inside the namespace are the caller's job — the prefix walk
    /// already reaches them, and returning them here would put every one into
    /// a captured collection for nothing.
    @Test("a descendant inside the namespace is left to the prefix walk")
    func inNamespaceDescendantsAreExcluded() {
        let parents = ["core.note.annotated": "core.note", "user.annotated": "core.note"]
        #expect(descendants(of: "core.note", parents) == ["user.annotated"])
    }
}
