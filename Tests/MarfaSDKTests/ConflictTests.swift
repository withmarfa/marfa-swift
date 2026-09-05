import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

@Suite("Conflict Resolution")
struct ConflictTests {

    // MARK: - Wire decoding

    @Test("ConflictResponse decodes conflicting_fields wire name to conflictingFields")
    func conflictResponseCamelCaseMapping() throws {
        let body = #"""
        {
            "error": {"code": "version_conflict", "message": "Version conflict", "status": 409},
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
            "error": {"code": "version_conflict", "message": "Version conflict"},
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
            "error": {"code": "version_conflict", "message": "Version conflict", "status": 409},
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

    // MARK: - Resolution belongs to the server

    /// **The request is the whole behaviour, so the request is what is
    /// asserted.** The server ignores a query parameter it does not know, so
    /// a kit that sent nothing would still look correct against any mock
    /// that answers 200 — reading the merged result would pass either way.
    @Test("the auto strategy asks the server to resolve")
    func autoSendsTheConflictParameter() async throws {
        let transport = MockTransport()
        transport.enqueue(ItemResponse(item: makeNoteItem(id: "n1", title: "T", body: "B", version: 2)))

        _ = try await handleConflictUpdate(
            transport: transport,
            itemId: "n1",
            clientPatch: ["title": .string("T")],
            version: 1,
            strategy: .auto,
            resolver: nil
        )

        let patch = try #require(transport.calls.first(where: { $0.method == .patch }))
        let sent = try #require(patch.query)
        #expect(sent.contains(where: { $0.0 == "conflict" && $0.1 == "auto" }))
    }

    /// `manual` and `callback` both mean the caller resolves, and the route's
    /// default for an omitted parameter is already `manual` — so silence says
    /// exactly what they mean, and sending `conflict=manual` would be noise
    /// that a future default change would silently pin.
    @Test("manual and callback ask for the envelope by saying nothing")
    func manualAndCallbackSendNoConflictParameter() async throws {
        for strategy in [ConflictStrategy.manual, .callback] {
            let transport = MockTransport()
            transport.enqueue(ItemResponse(item: makeNoteItem(id: "n1", title: "T", body: "B", version: 2)))

            _ = try await handleConflictUpdate(
                transport: transport,
                itemId: "n1",
                clientPatch: ["title": .string("T")],
                version: 1,
                strategy: strategy,
                resolver: { _ in [:] }
            )

            let patch = try #require(transport.calls.first(where: { $0.method == .patch }))
            #expect(
                !(patch.query ?? []).contains(where: { $0.0 == "conflict" }),
                "\(strategy) should send no conflict parameter"
            )
        }
    }

    /// The sibling's id reaches the app only because the server reports it
    /// here: no route says what a write created, so dropping
    /// `conflict_resolution` would lose the conflicted copy entirely — it
    /// would exist on the server and be unreachable from the device.
    @Test("a resolved write reports the server's resolution, sibling id included")
    func resolvedWriteReportsWhatTheServerDid() async throws {
        let transport = MockTransport()
        let item = makeNoteItem(id: "n1", title: "server title", body: "server body", version: 3)
        let itemJSON = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(item))
        transport.enqueue(JSONValue.dictionary([
            "item": itemJSON,
            "conflict_resolution": .dictionary([
                "fields": .array([.string("body"), .string("title")]),
                "strategy": .dictionary([
                    "body": .string("keep_both_copies"),
                    "title": .string("last_writer_wins"),
                ]),
                "conflicted_copy_id": .string("n1-copy"),
            ]),
        ]))

        let result = try await handleConflictUpdateWithStats(
            transport: transport,
            itemId: "n1",
            clientPatch: ["body": .string("mine")],
            version: 1,
            strategy: .auto,
            resolver: nil
        )

        let summary = try #require(result.mergeSummary)
        #expect(summary.conflictedCopyId == "n1-copy")
        #expect(summary.fields == ["body", "title"])
        #expect(summary.strategy["body"] == .keepBothCopies)
        #expect(summary.strategy["title"] == .lastWriterWins)
        // The device reports; it does not act. A sibling spawned here would
        // be a second copy of the one the server already made.
        #expect(!transport.calls.contains(where: { $0.path == "/items" && $0.method == .post }))
    }

    /// An ordinary write carries no `conflict_resolution`, so nothing is
    /// reported. Without this the summary would have to be inferred from
    /// something else, which is the inference this change removes.
    @Test("a write that resolved nothing reports nothing")
    func unconflictedWriteReportsNoResolution() async throws {
        let transport = MockTransport()
        transport.enqueue(ItemResponse(item: makeNoteItem(id: "n1", title: "T", body: "B", version: 2)))

        let result = try await handleConflictUpdateWithStats(
            transport: transport,
            itemId: "n1",
            clientPatch: ["title": .string("T")],
            version: 1,
            strategy: .auto,
            resolver: nil
        )

        #expect(result.mergeSummary == nil)
    }

    /// A 409 that comes back under `conflict=auto` is one the server *could*
    /// not resolve, not one it declined to. Merging it here would restore the
    /// second implementation of a rule that now has one home — and the two
    /// implementations disagreed, the kit keeping the earlier write where the
    /// server keeps the later one.
    @Test("an unresolved conflict under auto surfaces instead of merging on the device")
    func autoDoesNotMergeOnTheDevice() async throws {
        let transport = MockTransport()
        try enqueueConflict(
            on: transport,
            currentVersion: 5,
            currentProps: ["title": .string("server"), "body": .string("server body")],
            ancestorProps: ["title": .string("base"), "body": .string("base body")],
            conflictingFields: ["title", "body"],
            policy: notePolicy()
        )

        await #expect(throws: ConflictError.self) {
            _ = try await handleConflictUpdate(
                transport: transport,
                itemId: "n1",
                clientPatch: ["title": .string("mine"), "body": .string("my body")],
                version: 1,
                strategy: .auto,
                resolver: nil
            )
        }

        #expect(!transport.calls.contains(where: { $0.path == "/items" && $0.method == .post }))
        #expect(transport.calls.filter { $0.method == .patch }.count == 1, "no retry: the server already tried")
    }

    /// **A thinned ancestor is recoverable, and this is where it recovers.**
    /// The server refused a write against a version it no longer retains and
    /// handed back the version it does hold. Under `.auto` that is enough to
    /// rebase on and retry, which is the whole reason the error carries
    /// `current` — and without this the row parks as an unresolved conflict
    /// whose stated remedy, `retry(id:)`, re-sends the same stale version and
    /// fails identically, forever.
    @Test("a thinned ancestor rebases onto the server's version and retries")
    func thinnedAncestorRebasesUnderAuto() async throws {
        let transport = MockTransport()
        transport.enqueueError(AncestorUnavailableError(
            current: ConflictSnapshot(properties: ["title": .string("server")], version: 11),
            requestedVersion: 3,
            message: "version 3 is no longer retained"
        ))
        transport.enqueue(ItemResponse(item: makeNoteItem(id: "n1", title: "mine", body: "b", version: 12)))

        let item = try await handleConflictUpdate(
            transport: transport,
            itemId: "n1",
            clientPatch: ["title": .string("mine")],
            version: 3,
            strategy: .auto,
            resolver: nil
        )

        #expect(item.version == 12)
        let patches = transport.calls.filter { $0.method == .patch }
        #expect(patches.count == 2, "the refused attempt should have been retried")
        let retried = try #require(patches.last?.body)
        let sent = try JSONDecoder().decode(UpdateItemBody.self, from: retried)
        #expect(sent.version == 11, "the retry must carry the version the server said it holds")
    }

    /// **The rebased retry is keyed too, and its key names the version it
    /// rebases onto.** Without one, a lost response on the retry replays the
    /// whole row: attempt zero repeats under the row's key and is answered
    /// with the stored refusal, the write rebases again onto whatever the
    /// server now holds, and the patch is applied a second time. The key
    /// cannot simply be the row's, because the retry carries a different body
    /// and the server refuses a key replayed with a different request — so it
    /// is derived from the version, which is exactly what changed.
    @Test("the rebased retry carries a key derived from the version it rebases onto")
    func rebasedRetryIsKeyedByVersion() async throws {
        let transport = MockTransport()
        transport.enqueueError(AncestorUnavailableError(
            current: ConflictSnapshot(properties: [:], version: 11),
            requestedVersion: 3,
            message: "gone"
        ))
        transport.enqueue(ItemResponse(item: makeNoteItem(id: "n1", title: "mine", body: "b", version: 12)))

        _ = try await handleConflictUpdate(
            transport: transport,
            itemId: "n1",
            clientPatch: ["title": .string("mine")],
            version: 3,
            strategy: .auto,
            resolver: nil,
            idempotencyKey: "row-key"
        )

        let patches = transport.calls.filter { $0.method == .patch }
        #expect(patches.first?.idempotencyKey == "row-key")
        #expect(patches.last?.idempotencyKey == "row-key-v11",
                "the retry needs a key, and one that changes with the body it sends")
    }

    /// **A resolver's retry is keyed too, but minted rather than derived.**
    /// A rebase re-sends a body that is a function of the row and the server's
    /// version, so it can be *named*; a resolver returns whatever it likes, so
    /// the same derivation could name two different requests, which the server
    /// refuses. A fresh key names this request exactly and is strictly better
    /// than none — it covers the transport's own retry of this attempt, which
    /// is the window where a timeout replays a write the server may already
    /// have taken. What it cannot do is dedupe across drains, and nor could
    /// `nil`.
    @Test("a resolver-driven retry carries a freshly minted key, not the row's")
    func resolverRetryIsKeyedWithAFreshKey() async throws {
        let transport = MockTransport()
        try enqueueConflict(
            on: transport,
            currentVersion: 5,
            currentProps: ["title": .string("server")],
            ancestorProps: ["title": .string("base")],
            conflictingFields: ["title"],
            policy: notePolicy()
        )
        transport.enqueue(ItemResponse(item: makeNoteItem(id: "n1", title: "resolved", body: "b", version: 6)))

        _ = try await handleConflictUpdate(
            transport: transport,
            itemId: "n1",
            clientPatch: ["title": .string("mine")],
            version: 1,
            strategy: .callback,
            resolver: { _ in ["title": .string("resolved")] },
            idempotencyKey: "row-key"
        )

        let patches = transport.calls.filter { $0.method == .patch }
        #expect(patches.count == 2)
        #expect(patches.first?.idempotencyKey == "row-key")
        let retryKey = try #require(patches.last?.idempotencyKey,
            "an unkeyed resolver retry is a write the transport can replay after a timeout")
        #expect(retryKey != "row-key",
            "reusing the row's key on a different body is refused as idempotency_key_reused")
    }

    /// **`manual` and `callback` mean the caller resolves, and that includes
    /// this.** Rebasing under them would apply an edit to a base the caller
    /// never saw, which is the decision they exist to keep.
    @Test("a thinned ancestor surfaces to the caller under manual")
    func thinnedAncestorSurfacesUnderManual() async throws {
        let transport = MockTransport()
        transport.enqueueError(AncestorUnavailableError(
            current: ConflictSnapshot(properties: [:], version: 11),
            requestedVersion: 3,
            message: "gone"
        ))

        await #expect(throws: AncestorUnavailableError.self) {
            _ = try await handleConflictUpdate(
                transport: transport,
                itemId: "n1",
                clientPatch: ["title": .string("mine")],
                version: 3,
                strategy: .manual,
                resolver: nil
            )
        }
        #expect(transport.calls.filter { $0.method == .patch }.count == 1)
    }

    /// **A row enqueued before the key column existed replays exactly as it
    /// always did — on its first attempt.** That is the whole property the
    /// missing key protects, and it is about what happens across drains. A
    /// later attempt is a different request either way, so minting a key for
    /// it protects nothing less and leaves one fewer unkeyed write on a route
    /// the server keys.
    @Test("a row with no key still keys its retries")
    func legacyRowKeysItsRetries() {
        #expect(keyForAttempt(attempt: 0, rowKey: nil, rebased: false, version: 5) == nil)
        #expect(keyForAttempt(attempt: 1, rowKey: nil, rebased: false, version: 5) != nil)
        #expect(keyForAttempt(attempt: 1, rowKey: nil, rebased: true, version: 5) != nil)
    }

    /// Two mints are two requests, which is the point — a key that repeated
    /// across attempts would name two different bodies and be refused.
    @Test("each minted retry key is its own")
    func mintedKeysDiffer() {
        let a = keyForAttempt(attempt: 1, rowKey: "row", rebased: false, version: 5)
        let b = keyForAttempt(attempt: 2, rowKey: "row", rebased: false, version: 5)
        #expect(a != nil)
        #expect(a != b)
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
            error: ConflictResponseError(code: .versionConflict, message: "Version conflict", status: 409),
            mergePolicy: policy
        )
        transport.enqueue(response)
    }
}
