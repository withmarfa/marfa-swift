import Foundation
import Testing
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// What a `metadata.changed` event does to the local store.
///
/// Nothing exercised this decode against a frame the server actually sends,
/// which is how the SDK came to read an `item_id` the envelope has never
/// carried: every such frame failed to decode and was dropped, and a tag added
/// on one device reached another only when that device re-imported. So these
/// tests feed the envelope verbatim — `{ type, item, metadata }`, the same
/// shape every item event uses — rather than a payload shaped to the decoder.
@Suite("What a metadata.changed event applies", .timeLimit(.minutes(1)))
struct SyncEngineMetadataEventTests {

    // MARK: - Fixtures

    /// The server's envelope for a metadata event, encoded as it arrives.
    private struct MetadataFrame: Encodable {
        let type: String
        let item: Item
        let metadata: Metadata
    }

    private func item(_ id: String, body: String = "b") -> Item {
        Item(
            createdAt: "2026-09-02T09:00:00Z",
            id: id,
            properties: ["body": .string(body)],
            schemaVersion: 1,
            source: "test",
            state: .active,
            tier: .feed,
            timestamp: "2026-09-02T09:00:00Z",
            type: "core.note",
            updatedAt: "2026-09-02T09:00:00Z",
            version: 1
        )
    }

    private func frame(
        id: String,
        item: Item,
        tags: [String],
        extensions: [String: [String: JSONValue]]
    ) throws -> SSEEvent {
        let wrapped = extensions.mapValues { JSONValue.dictionary($0) }
        let payload = MetadataFrame(
            type: "metadata.changed",
            item: item,
            metadata: Metadata(extensions: wrapped, itemId: item.id, tags: tags)
        )
        let data = try JSONEncoder().encode(payload)
        return SSEEvent(
            id: id,
            event: "metadata.changed",
            data: String(data: data, encoding: .utf8) ?? ""
        )
    }

    private func noteInput() -> CreateItemInput {
        CreateItemInput(type: "core.note", properties: ["body": .string("x")])
    }

    // MARK: - Tests

    @Test("the frame the server sends changes the tags and lands the extensions")
    func theRealFrameApplies() async throws {
        let (store, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        let extensions = ExtensionsNamespace(
            transport: transport, localStore: store, mutationQueue: queue
        )
        let stored = try await store.createItem(noteInput())

        transport.enqueueEvents([
            try frame(
                id: "evt-1",
                item: item(stored.id),
                tags: ["urgent"],
                extensions: ["app": ["state": .string("from the server")]]
            )
        ])

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.waitUntil(
            timeout: .milliseconds(500),
            description: "the event's tag to reach the local metadata row"
        ) {
            (try? await store.fetchMetadata(itemId: stored.id))?.tags.contains("urgent") ?? false
        }

        let namespace = try await extensions.get(itemId: stored.id, namespace: "app")
        #expect(namespace?["state"] == .string("from the server"))
        await engine.stop()
    }

    @Test("an extension the event carries is still there afterwards")
    func anExtensionTheEventCarriesSurvives() async throws {
        let (store, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        let extensions = ExtensionsNamespace(
            transport: transport, localStore: store, mutationQueue: queue
        )
        let stored = try await store.createItem(noteInput())
        _ = try await store.setExtension(
            itemId: stored.id, namespace: "app", data: ["state": .string("written here")]
        )

        // The write above reached the server before the tag was added
        // elsewhere, so the row the event carries holds it. An app that wrote
        // an extension has no way to know the next tag from anywhere would
        // take it, which is what made the old behavior silent.
        transport.enqueueEvents([
            try frame(
                id: "evt-1",
                item: item(stored.id),
                tags: ["tagged-elsewhere"],
                extensions: ["app": ["state": .string("written here")]]
            )
        ])

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.waitUntil(
            timeout: .milliseconds(500),
            description: "the event's tag to reach the local metadata row"
        ) {
            (try? await store.fetchMetadata(itemId: stored.id))?.tags.contains("tagged-elsewhere") ?? false
        }

        let namespace = try await extensions.get(itemId: stored.id, namespace: "app")
        #expect(namespace?["state"] == .string("written here"))
        await engine.stop()
    }

    @Test("a namespace the event leaves out is removed")
    func aNamespaceAbsentFromTheEventIsRemoved() async throws {
        let (store, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        let extensions = ExtensionsNamespace(
            transport: transport, localStore: store, mutationQueue: queue
        )
        let stored = try await store.createItem(noteInput())
        _ = try await store.setExtension(itemId: stored.id, namespace: "kept", data: ["k": .string("v")])
        _ = try await store.setExtension(itemId: stored.id, namespace: "dropped", data: ["k": .string("w")])

        // The row is the server's, so a namespace it does not mention is one
        // the server no longer holds — a removal from another device reaches
        // this one as an absence rather than as its own event.
        transport.enqueueEvents([
            try frame(
                id: "evt-1",
                item: item(stored.id),
                tags: [],
                extensions: ["kept": ["k": .string("v")]]
            )
        ])

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.waitUntil(
            timeout: .milliseconds(500),
            description: "the namespace the event left out to be gone locally"
        ) {
            (try? await extensions.get(itemId: stored.id, namespace: "dropped")) == nil
        }

        let kept = try await extensions.get(itemId: stored.id, namespace: "kept")
        #expect(kept?["k"] == .string("v"))
        await engine.stop()
    }

    @Test("a frame for an item this device has never seen lands both halves")
    func aFrameForAnUnknownItemLandsTheItemToo() async throws {
        let (store, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        let metadata = MetadataNamespace(
            transport: transport, localStore: store, mutationQueue: queue
        )
        let unknown = item("server-never-seen")

        transport.enqueueEvents([
            try frame(
                id: "evt-1",
                item: unknown,
                tags: ["arrived"],
                extensions: [:]
            )
        ])

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.waitUntil(
            timeout: .milliseconds(500),
            description: "the item the frame carried to be in the store"
        ) {
            (try? await store.fetchItem(id: unknown.id)) != nil
        }

        #expect(try await metadata.get(itemId: unknown.id).tags == ["arrived"])
        // A metadata row written with no item to attach to contributes no
        // tags: `listTags` counts only rows whose parent item is present.
        // This is what tells a stored-both-halves apart from a stored-the-
        // sidecar-and-orphaned-it.
        let tags = try await metadata.listTags()
        #expect(tags.contains { $0.tag == "arrived" && $0.count == 1 })
        await engine.stop()
    }
}
