import Foundation
import Testing
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// What an inbound item event leaves in the store.
///
/// Two properties, and each one is only worth asserting alongside the other.
///
/// **A queued edit stays visible.** The frame used to replace the row with the
/// server's copy, so text a person was still typing vanished from under them
/// and came back when the queue drained. Asserting only that the edit survives
/// would pass against an engine that ignored inbound frames entirely, so every
/// test here also asserts the other device's change landed.
///
/// **A frame older than the row does not apply.** The apply was unconditional,
/// so a frame arriving behind a newer write regressed the row it described.
///
/// Frames go through `_applyEventForTesting` rather than a live stream: none of
/// this is about the stream, and driving one would put a connection transition
/// and a poll between the frame and the assertion, so a failure would arrive as
/// a timeout a busy machine can produce on its own.
@Suite("What an inbound item event leaves in the store", .timeLimit(.minutes(1)))
struct SyncEngineInboundRebaseTests {

    // MARK: - Fixtures

    private func item(
        _ id: String,
        title: String,
        body: String,
        state: ItemState = .active,
        version: Int
    ) -> Item {
        Item(
            createdAt: "2026-09-03T09:00:00Z",
            id: id,
            properties: ["title": .string(title), "body": .string(body)],
            schemaVersion: 1,
            source: "test",
            state: state,
            tier: .feed,
            timestamp: "2026-09-03T09:00:00Z",
            type: "core.note",
            updatedAt: "2026-09-03T09:00:00Z",
            version: version
        )
    }

    private struct ItemFrame: Encodable {
        let type: String
        let item: Item
        let metadata: Metadata?
    }

    private func frame(
        _ type: String,
        _ item: Item,
        metadata: Metadata? = nil,
        id: String = "evt-1"
    ) throws -> SSEEvent {
        let data = try JSONEncoder().encode(ItemFrame(type: type, item: item, metadata: metadata))
        return SSEEvent(id: id, event: type, data: String(decoding: data, as: UTF8.self))
    }

    private func items(
        _ store: LocalStore,
        _ queue: MutationQueue,
        _ transport: MockTransport
    ) -> ItemsNamespace {
        ItemsNamespace(
            transport: transport,
            defaultConflictStrategy: .auto,
            localStore: store,
            mutationQueue: queue
        )
    }

    private func text(_ item: Item, _ key: String) -> String? {
        if case .string(let value) = item.properties[key] { return value }
        return nil
    }

    // MARK: - A queued edit stays visible

    @Test("an unsent edit survives the frame, and the other device's field lands")
    func pendingEditSurvivesAndTheOtherFieldLands() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await store.upsertItem(item("i1", title: "Draft", body: "first pass", version: 1))

        // The person is typing. The write is local and queued; the server has
        // not seen it.
        _ = try await items(store, queue, transport).update(
            id: "i1", properties: ["body": .string("second pass")]
        )

        // Another device renamed the note. Different field, same row.
        await engine._applyEventForTesting(
            try frame("item.updated", item("i1", title: "Renamed", body: "first pass", version: 2))
        )

        let stored = try await store.fetchItem(id: "i1")
        #expect(text(stored, "body") == "second pass")
        #expect(text(stored, "title") == "Renamed")
    }

    @Test("an unsent trash survives the frame, and the other device's field lands")
    func pendingTrashSurvivesAndTheOtherFieldLands() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await store.upsertItem(item("i1", title: "Draft", body: "first pass", version: 1))

        try await items(store, queue, transport).delete(id: "i1")

        await engine._applyEventForTesting(
            try frame("item.updated", item("i1", title: "Renamed", body: "first pass", version: 2))
        )

        let stored = try await store.fetchItem(id: "i1")
        #expect(stored.state == .trashed)
        #expect(text(stored, "title") == "Renamed")
    }

    @Test("a metadata.changed frame lands its tags without discarding an unsent edit")
    func metadataFrameKeepsThePendingEdit() async throws {
        // `metadata.changed` carries the item alongside the sidecar and applies
        // both, so it had the same exposure as `item.updated` and needed the
        // same fix rather than a second one.
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await store.upsertItem(item("i1", title: "Draft", body: "first pass", version: 1))

        _ = try await items(store, queue, transport).update(
            id: "i1", properties: ["body": .string("second pass")]
        )

        await engine._applyEventForTesting(
            try frame(
                "metadata.changed",
                item("i1", title: "Draft", body: "first pass", version: 1),
                metadata: Metadata(extensions: [:], itemId: "i1", tags: ["urgent"])
            )
        )

        let stored = try await store.fetchItem(id: "i1")
        #expect(text(stored, "body") == "second pass")
        #expect(try await store.fetchMetadata(itemId: "i1").tags == ["urgent"])
    }

    // MARK: - A frame older than the row does not apply

    @Test("a frame behind the row does not regress it")
    func staleFrameDoesNotRegressTheRow() async throws {
        let (store, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await store.upsertItem(item("i1", title: "Current", body: "current", version: 5))

        await engine._applyEventForTesting(
            try frame("item.updated", item("i1", title: "Old", body: "old", version: 3))
        )

        let stored = try await store.fetchItem(id: "i1")
        #expect(text(stored, "title") == "Current")
        #expect(stored.version == 5)
    }

    @Test("a frame ahead of the row does apply")
    func freshFrameApplies() async throws {
        // Control for the test above. A guard that refused everything would
        // pass it and would be a worse defect than the one it replaced.
        let (store, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await store.upsertItem(item("i1", title: "Current", body: "current", version: 5))

        await engine._applyEventForTesting(
            try frame("item.updated", item("i1", title: "Newer", body: "newer", version: 6))
        )

        let stored = try await store.fetchItem(id: "i1")
        #expect(text(stored, "title") == "Newer")
        #expect(stored.version == 6)
    }

    @Test("a frame at the row's own version still applies")
    func sameVersionFrameApplies() async throws {
        // The guard is "not older" rather than "newer". A re-delivered frame at
        // the version the row already holds is an idempotent write, and
        // refusing it would drop the resume that follows every reconnect.
        let (store, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await store.upsertItem(item("i1", title: "Current", body: "current", version: 5))

        await engine._applyEventForTesting(
            try frame("item.updated", item("i1", title: "Same version", body: "current", version: 5))
        )

        #expect(text(try await store.fetchItem(id: "i1"), "title") == "Same version")
    }

    @Test("a frame for a row this device has never seen applies")
    func unknownRowApplies() async throws {
        // There is no stored version to be older than. A guard reading a
        // missing row as version zero would be fine; one reading it as a
        // refusal would lose every item created before this device's cursor.
        let (store, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()

        await engine._applyEventForTesting(
            try frame("item.created", item("new", title: "Fresh", body: "fresh", version: 1))
        )

        #expect(text(try await store.fetchItem(id: "new"), "title") == "Fresh")
    }

    // MARK: - Layering

    @Test("an item frame leaves the metadata row alone")
    func itemFrameDoesNotTouchMetadata() async throws {
        // The server writes metadata through its own layer and announces it as
        // `metadata.changed`. An item frame carries the sidecar too, and taking
        // it here would put one field in two places and leave the two able to
        // disagree. Pinned rather than assumed, because this change introduces
        // a second write path onto the item row.
        let (store, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await store.upsertItem(item("i1", title: "Draft", body: "first pass", version: 1))
        try await store.upsertMetadata(
            Metadata(extensions: [:], itemId: "i1", tags: ["kept"])
        )

        await engine._applyEventForTesting(
            try frame(
                "item.updated",
                item("i1", title: "Renamed", body: "first pass", version: 2),
                metadata: Metadata(extensions: [:], itemId: "i1", tags: ["from the item frame"])
            )
        )

        #expect(try await store.fetchMetadata(itemId: "i1").tags == ["kept"])
        #expect(text(try await store.fetchItem(id: "i1"), "title") == "Renamed")
    }
}
