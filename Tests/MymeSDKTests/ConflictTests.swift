import Testing
import Foundation
@testable import MymeSDK
@testable import MymeSDKTestSupport

@Suite("Conflict Resolution")
struct ConflictTests {

    // MARK: - Pure auto-merge primitive (last-writer-wins)

    @Test("Auto-merge keeps client changes for non-conflicting fields")
    func autoMergeNonConflicting() {
        let conflict = ConflictData(
            current: ConflictSnapshot(properties: [
                "title": .string("Server Title"),
                "body": .string("Server Body"),
            ], version: 2),
            ancestor: ConflictSnapshot(properties: [
                "title": .string("Original Title"),
                "body": .string("Original Body"),
            ], version: 1),
            conflictingFields: ["title"],
            clientPatch: [
                "title": .string("Client Title"),
                "body": .string("Client Body"),
            ],
            mergePolicy: nil
        )

        let merged = autoMerge(conflict: conflict)

        // Server wins on conflicting field
        #expect(merged["title"] == .string("Server Title"))
        // Client wins on non-conflicting field
        #expect(merged["body"] == .string("Client Body"))
    }

    @Test("Auto-merge with no conflicts applies all client changes")
    func autoMergeNoConflicts() {
        let conflict = ConflictData(
            current: ConflictSnapshot(properties: [
                "title": .string("Server Title"),
            ], version: 2),
            ancestor: ConflictSnapshot(properties: [:], version: 1),
            conflictingFields: [],
            clientPatch: [
                "title": .string("Client Title"),
                "body": .string("New Body"),
            ],
            mergePolicy: nil
        )

        let merged = autoMerge(conflict: conflict)

        #expect(merged["title"] == .string("Client Title"))
        #expect(merged["body"] == .string("New Body"))
    }

    @Test("Auto-merge with all fields conflicting keeps server values")
    func autoMergeAllConflicting() {
        let conflict = ConflictData(
            current: ConflictSnapshot(properties: [
                "title": .string("Server Title"),
                "body": .string("Server Body"),
            ], version: 2),
            ancestor: ConflictSnapshot(properties: [:], version: 1),
            conflictingFields: ["title", "body"],
            clientPatch: [
                "title": .string("Client Title"),
                "body": .string("Client Body"),
            ],
            mergePolicy: nil
        )

        let merged = autoMerge(conflict: conflict)

        #expect(merged["title"] == .string("Server Title"))
        #expect(merged["body"] == .string("Server Body"))
    }

    // MARK: - Per-field strategy resolution

    @Test("strategyForField uses field-level entry over default")
    func strategyForFieldUsesFieldLevel() {
        let policy = MergePolicy(
            default: .lastWriterWins,
            fields: ["body": .keepBothCopies]
        )
        #expect(strategyForField("body", policy: policy) == .keepBothCopies)
        #expect(strategyForField("title", policy: policy) == .lastWriterWins)
    }

    @Test("strategyForField falls back to default when field absent")
    func strategyForFieldFallsBackToDefault() {
        let policy = MergePolicy(default: .keepBothCopies, fields: nil)
        #expect(strategyForField("anything", policy: policy) == .keepBothCopies)
    }

    @Test("strategyForField defaults to last_writer_wins when policy is nil")
    func strategyForFieldNilPolicy() {
        #expect(strategyForField("body", policy: nil) == .lastWriterWins)
    }

    // MARK: - Wire decoding

    @Test("ConflictResponse decodes conflicting_fields wire name to conflictingFields")
    func conflictResponseCamelCaseMapping() throws {
        let body = #"""
        {
            "error": {"code": "version_conflict", "status": 409},
            "current": {"version": 2, "properties": {"title": "Server"}},
            "ancestor": {"version": 1, "properties": {"title": "Original"}},
            "conflicting_fields": ["title"],
            "merge_policy": {"default": "last_writer_wins"}
        }
        """#

        let response = try JSONDecoder().decode(ConflictResponse.self, from: Data(body.utf8))

        #expect(response.conflictingFields == ["title"])
        #expect(response.current.version == 2)
        #expect(response.ancestor.version == 1)
        #expect(response.mergePolicy.`default` == .lastWriterWins)
    }

    @Test("ConflictResponse decoding fails when ancestor is absent")
    func conflictResponseRequiresAncestor() {
        let body = #"""
        {
            "error": {"code": "version_conflict"},
            "current": {"version": 2, "properties": {}},
            "conflicting_fields": [],
            "merge_policy": {}
        }
        """#

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ConflictResponse.self, from: Data(body.utf8))
        }
    }

    @Test("ConflictResponse decoding fails when merge_policy is absent")
    func conflictResponseRequiresMergePolicy() {
        let body = #"""
        {
            "error": {"code": "version_conflict", "status": 409},
            "current": {"version": 2, "properties": {}},
            "ancestor": {"version": 1, "properties": {}},
            "conflicting_fields": []
        }
        """#

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ConflictResponse.self, from: Data(body.utf8))
        }
    }

    @Test("MergePolicy decodes per-field strategies")
    func mergePolicyDecoding() throws {
        let body = #"""
        {
            "default": "last_writer_wins",
            "fields": { "body": "keep_both_copies", "notes": "keep_both_copies" }
        }
        """#

        let policy = try JSONDecoder().decode(MergePolicy.self, from: Data(body.utf8))
        #expect(policy.`default` == .lastWriterWins)
        #expect(policy.fields?["body"] == .keepBothCopies)
        #expect(policy.fields?["notes"] == .keepBothCopies)
    }

    // MARK: - Policy-aware autoMerge end-to-end (mocked transport)

    /// `core.note` body conflict, body declared keep-both ⇒ sibling spawned,
    /// original retains server body, applied strategy recorded.
    @Test("core.note body conflict spawns conflicted-copy sibling")
    func keepBothSpawnsSiblingForCoreNoteBody() async throws {
        let transport = MockTransport()

        // 1) PATCH /items/<id> → 409 with merge_policy = body keep-both
        try enqueueConflict(
            on: transport,
            currentVersion: 2,
            currentProps: [
                "title": .string("Server title"),
                "body": .string("Server body"),
            ],
            ancestorProps: [
                "title": .string("Original title"),
                "body": .string("Original body"),
            ],
            conflictingFields: ["body"],
            policy: notePolicy()
        )

        // 2) GET /items/<id> → original item (need its type for keepBothFlow)
        let originalItem = makeNoteItem(
            id: "note-1",
            title: "Server title",
            body: "Server body",
            version: 2
        )
        transport.enqueue(ItemResponse(item: originalItem))

        // 3) POST /items → spawned sibling
        let sibling = makeNoteItem(
            id: "note-2",
            title: "Server title",
            body: "Client body in flight",
            version: 1
        )
        transport.enqueue(ItemResponse(item: sibling))

        // 4) PATCH retry → success (server-wins for body in the merged patch)
        let merged = makeNoteItem(
            id: "note-1",
            title: "Server title",
            body: "Server body",
            version: 3
        )
        transport.enqueue(ItemResponse(item: merged))

        let result = try await handleConflictUpdateWithStats(
            transport: transport,
            itemId: "note-1",
            clientPatch: ["body": .string("Client body in flight")],
            version: 1,
            strategy: .auto,
            resolver: nil
        )

        #expect(result.item.id == "note-1")
        let summary = try #require(result.mergeSummary)
        #expect(summary.itemId == "note-1")
        #expect(summary.mergedItemId == "note-1")
        #expect(summary.conflictedCopyId == "note-2")
        #expect(summary.fields == ["body"])
        #expect(summary.strategy["body"] == .keepBothCopies)

        // Verify the sibling create body carries the inline tag and the
        // client's body value.
        let createCall = try #require(transport.calls.first(where: { $0.path == "/items" && $0.method == .post }))
        let createBody = try JSONDecoder().decode(CreateItemInput.self, from: try #require(createCall.body))
        #expect(createBody.type == "core.note")
        #expect(createBody.tags == [conflictedCopyTag])
        #expect(createBody.properties["body"] == .string("Client body in flight"))
        #expect(createBody.properties["title"] == .string("Server title"))
    }

    /// `core.note` title conflict, title is last-writer-wins ⇒ no sibling,
    /// merged patch carries the server's title.
    @Test("core.note title conflict keeps server value, no sibling")
    func lastWriterWinsForCoreNoteTitle() async throws {
        let transport = MockTransport()

        try enqueueConflict(
            on: transport,
            currentVersion: 2,
            currentProps: [
                "title": .string("Server title"),
                "body": .string("Same body"),
            ],
            ancestorProps: [
                "title": .string("Original title"),
                "body": .string("Same body"),
            ],
            conflictingFields: ["title"],
            policy: notePolicy()
        )

        // PATCH retry → success
        transport.enqueue(ItemResponse(item: makeNoteItem(
            id: "note-1",
            title: "Server title",
            body: "Same body",
            version: 3
        )))

        let result = try await handleConflictUpdateWithStats(
            transport: transport,
            itemId: "note-1",
            clientPatch: ["title": .string("Client title")],
            version: 1,
            strategy: .auto,
            resolver: nil
        )

        let summary = try #require(result.mergeSummary)
        #expect(summary.conflictedCopyId == nil)
        #expect(summary.fields == ["title"])
        #expect(summary.strategy["title"] == .lastWriterWins)

        // No POST /items in the call log.
        #expect(!transport.calls.contains(where: { $0.path == "/items" && $0.method == .post }))
    }

    /// Mixed conflict on body (keep-both) + title (last-writer-wins): sibling
    /// carries the body diff only; original retains server values for both.
    @Test("core.note mixed conflict: sibling for body diff, server-wins on title")
    func mixedConflictSpawnsSiblingForKeepBothFieldOnly() async throws {
        let transport = MockTransport()

        try enqueueConflict(
            on: transport,
            currentVersion: 2,
            currentProps: [
                "title": .string("Server title"),
                "body": .string("Server body"),
            ],
            ancestorProps: [
                "title": .string("Original title"),
                "body": .string("Original body"),
            ],
            conflictingFields: ["title", "body"],
            policy: notePolicy()
        )

        transport.enqueue(ItemResponse(item: makeNoteItem(
            id: "note-1",
            title: "Server title",
            body: "Server body",
            version: 2
        )))
        transport.enqueue(ItemResponse(item: makeNoteItem(
            id: "note-2",
            title: "Server title",
            body: "Client body in flight",
            version: 1
        )))
        transport.enqueue(ItemResponse(item: makeNoteItem(
            id: "note-1",
            title: "Server title",
            body: "Server body",
            version: 3
        )))

        let result = try await handleConflictUpdateWithStats(
            transport: transport,
            itemId: "note-1",
            clientPatch: [
                "title": .string("Client title"),
                "body": .string("Client body in flight"),
            ],
            version: 1,
            strategy: .auto,
            resolver: nil
        )

        let summary = try #require(result.mergeSummary)
        #expect(summary.conflictedCopyId == "note-2")
        #expect(summary.fields.sorted() == ["body", "title"])
        #expect(summary.strategy["body"] == .keepBothCopies)
        #expect(summary.strategy["title"] == .lastWriterWins)

        // The spawned sibling carries the client's body, NOT the client's
        // title — title's last-writer-wins keeps it on the original only.
        let createCall = try #require(transport.calls.first(where: { $0.path == "/items" && $0.method == .post }))
        let createBody = try JSONDecoder().decode(CreateItemInput.self, from: try #require(createCall.body))
        #expect(createBody.properties["body"] == .string("Client body in flight"))
        #expect(createBody.properties["title"] == .string("Server title"))
    }

    /// `core.entity.person` has no keep-both fields; any conflict resolves
    /// last-writer-wins with no sibling spawn.
    @Test("core.entity.person given_name conflict spawns no sibling")
    func entityPersonNoKeepBothFields() async throws {
        let transport = MockTransport()

        let policy = MergePolicy(default: .lastWriterWins, fields: nil)
        try enqueueConflict(
            on: transport,
            currentVersion: 2,
            currentProps: ["given_name": .string("Server name")],
            ancestorProps: ["given_name": .string("Original name")],
            conflictingFields: ["given_name"],
            policy: policy
        )

        transport.enqueue(ItemResponse(item: makeItem(
            id: "person-1",
            type: "core.entity.person",
            properties: ["given_name": .string("Server name")],
            version: 3
        )))

        let result = try await handleConflictUpdateWithStats(
            transport: transport,
            itemId: "person-1",
            clientPatch: ["given_name": .string("Client name")],
            version: 1,
            strategy: .auto,
            resolver: nil
        )

        let summary = try #require(result.mergeSummary)
        #expect(summary.conflictedCopyId == nil)
        #expect(summary.strategy["given_name"] == .lastWriterWins)
        #expect(!transport.calls.contains(where: { $0.path == "/items" && $0.method == .post }))
    }

    // MARK: - Helpers

    /// `core.note` policy mirroring the artifact's table:
    /// `body`/`notes` keep-both, everything else last-writer-wins.
    private func notePolicy() -> MergePolicy {
        MergePolicy(
            default: .lastWriterWins,
            fields: ["body": .keepBothCopies, "notes": .keepBothCopies]
        )
    }

    private func makeNoteItem(
        id: String,
        title: String,
        body: String,
        version: Int
    ) -> Item {
        makeItem(
            id: id,
            type: "core.note",
            properties: [
                "title": .string(title),
                "body": .string(body),
            ],
            version: version
        )
    }

    private func makeItem(
        id: String,
        type: String,
        properties: [String: JSONValue],
        version: Int
    ) -> Item {
        Item(
            createdAt: "2026-04-19T12:00:00Z",
            id: id,
            origin: .user,
            properties: properties,
            schemaVersion: 1,
            source: "test",
            state: .active, tier: .feed,
            timestamp: "2026-04-19T12:00:00Z",
            type: type,
            updatedAt: "2026-04-19T12:00:00Z",
            version: version
        )
    }

    /// Enqueues a synthetic 409 conflict on the next `requestWithConflict`
    /// call. The MockTransport tries to decode the queued bytes as the
    /// expected response type first (here, `ItemResponse`); when that fails
    /// it falls back to decoding as `ConflictResponse` and yields
    /// `.conflict(...)`.
    private func enqueueConflict(
        on transport: MockTransport,
        currentVersion: Int,
        currentProps: [String: JSONValue],
        ancestorProps: [String: JSONValue],
        conflictingFields: [String],
        policy: MergePolicy
    ) throws {
        let response = ConflictResponse(
            ancestor: ConflictSnapshot(properties: ancestorProps, version: 1),
            conflictingFields: conflictingFields,
            current: ConflictSnapshot(properties: currentProps, version: currentVersion),
            error: ConflictResponseError(code: .versionConflict, status: 409),
            mergePolicy: policy
        )
        transport.enqueue(response)
    }
}
