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
///
/// Each frame goes straight through `_applyEventForTesting`. Nothing here is
/// about the stream, and driving one through `start()` would put a connection
/// transition and a poll between the frame and the assertion, so a failure
/// would arrive as a timeout that a busy machine can produce on its own.
@Suite("What a metadata.changed event applies", .timeLimit(.minutes(1)))
struct SyncEngineMetadataEventTests {

    // MARK: - Fixtures

    /// The server's envelope for a metadata event, encoded as it arrives.
    /// `metadata` is spread in only when the event carries a row, so it is
    /// omitted from the JSON entirely when absent rather than sent as null.
    private struct MetadataFrame: Encodable {
        let type: String
        let item: Item
        let metadata: Metadata?
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
        item: Item,
        tags: [String]?,
        extensions: [String: [String: JSONValue]] = [:]
    ) throws -> SSEEvent {
        let metadata = tags.map {
            Metadata(
                extensions: extensions.mapValues { JSONValue.dictionary($0) },
                itemId: item.id,
                tags: $0
            )
        }
        let payload = MetadataFrame(type: "metadata.changed", item: item, metadata: metadata)
        let encoder = JSONEncoder()
        return SSEEvent(
            id: "evt-1",
            event: "metadata.changed",
            data: String(data: try encoder.encode(payload), encoding: .utf8) ?? ""
        )
    }

    private func noteInput() -> CreateItemInput {
        CreateItemInput(type: "core.note", properties: ["body": .string("x")])
    }

    // MARK: - Tests

    @Test("the frame the server sends changes the tags and lands the extensions")
    func theRealFrameApplies() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        let extensions = ExtensionsNamespace(
            transport: transport, localStore: store, mutationQueue: queue
        )
        let stored = try await store.createItem(noteInput())

        await engine._applyEventForTesting(
            try frame(
                item: item(stored.id),
                tags: ["urgent"],
                extensions: ["app": ["state": .string("from the server")]]
            )
        )

        #expect(try await store.fetchMetadata(itemId: stored.id).tags == ["urgent"])
        let namespace = try await extensions.get(itemId: stored.id, namespace: "app")
        #expect(namespace?["state"] == .string("from the server"))
    }

    @Test("the event's value for a namespace replaces the local one whole")
    func theEventsNamespaceReplacesTheLocalOne() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        let extensions = ExtensionsNamespace(
            transport: transport, localStore: store, mutationQueue: queue
        )
        let stored = try await store.createItem(noteInput())
        _ = try await store.setExtension(
            itemId: stored.id,
            namespace: "app",
            data: ["state": .string("written here"), "only-local": .string("x")]
        )

        // A namespace is one value, not a bag of keys to merge into: the
        // server holds what it holds, and a key another device removed has no
        // event of its own to announce it. Asserting the value the test wrote
        // would pass against a handler that ignored extensions entirely.
        await engine._applyEventForTesting(
            try frame(
                item: item(stored.id),
                tags: ["tagged-elsewhere"],
                extensions: ["app": ["state": .string("changed elsewhere")]]
            )
        )

        let namespace = try await extensions.get(itemId: stored.id, namespace: "app")
        #expect(namespace?["state"] == .string("changed elsewhere"))
        #expect(namespace?["only-local"] == nil)
    }

    @Test("a namespace the event leaves out is removed")
    func aNamespaceAbsentFromTheEventIsRemoved() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        let extensions = ExtensionsNamespace(
            transport: transport, localStore: store, mutationQueue: queue
        )
        let stored = try await store.createItem(noteInput())
        _ = try await store.setExtension(itemId: stored.id, namespace: "kept", data: ["k": .string("v")])
        _ = try await store.setExtension(itemId: stored.id, namespace: "dropped", data: ["k": .string("w")])

        // The row is the server's, so a namespace it does not mention is one
        // the server no longer holds — a removal from another device reaches
        // this one as an absence rather than as its own event.
        await engine._applyEventForTesting(
            try frame(item: item(stored.id), tags: [], extensions: ["kept": ["k": .string("v")]])
        )

        #expect(try await extensions.get(itemId: stored.id, namespace: "dropped") == nil)
        let kept = try await extensions.get(itemId: stored.id, namespace: "kept")
        #expect(kept?["k"] == .string("v"))
    }

    @Test("a frame for an item this device has never seen lands both halves")
    func aFrameForAnUnknownItemLandsTheItemToo() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        let metadata = MetadataNamespace(
            transport: transport, localStore: store, mutationQueue: queue
        )
        let unknown = item("server-never-seen")

        await engine._applyEventForTesting(
            try frame(item: unknown, tags: ["arrived"])
        )

        #expect(try await store.fetchItem(id: unknown.id).id == unknown.id)
        #expect(try await metadata.get(itemId: unknown.id).tags == ["arrived"])
        // `listTags` counts only rows whose parent item is present, so this
        // discriminates the write order rather than the item write itself:
        // storing the metadata before the item leaves the row detached, and
        // nothing afterwards attaches it — the tag would be readable through
        // `metadata.get` and invisible to every aggregate over the store.
        let tags = try await metadata.listTags()
        #expect(tags.contains { $0.tag == "arrived" && $0.count == 1 })
    }

    @Test("a frame carrying no metadata stores the item and nothing else")
    func aFrameWithoutMetadataStoresOnlyTheItem() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        let metadata = MetadataNamespace(
            transport: transport, localStore: store, mutationQueue: queue
        )
        let stored = try await store.createItem(noteInput())
        _ = try await store.setMetadata(itemId: stored.id, input: MetadataInput(tags: ["kept"]))

        // The server spreads `metadata` into the envelope only when the event
        // carries a row, so the key is genuinely absent rather than null. A
        // decoder that required it would fail the frame and drop it silently,
        // which is exactly how this event came to be ignored in the first
        // place — so the absence has to be a shape the decoder accepts.
        await engine._applyEventForTesting(
            try frame(item: item(stored.id, body: "edited elsewhere"), tags: nil)
        )

        #expect(try await store.fetchItem(id: stored.id).properties["body"] == .string("edited elsewhere"))
        #expect(try await metadata.get(itemId: stored.id).tags == ["kept"])
    }
}
