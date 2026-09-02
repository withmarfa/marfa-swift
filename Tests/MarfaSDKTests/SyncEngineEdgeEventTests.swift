import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// What an `edge.*` frame leaves behind: the row in the local store, and the
/// event the engine publishes to its subscribers.
///
/// Frames are driven through `_applyEventForTesting` rather than through a
/// stream, so each test asserts the outcome of exactly one frame with nothing
/// to wait for. The engine's `events` stream buffers, so subscribing before
/// the apply and closing the engine after it turns the emission into a
/// finite list rather than a wait the test has to bound.
@Suite("SyncEngine edge events", .timeLimit(.minutes(1)))
struct SyncEngineEdgeEventTests {

    /// Builds the `{ type, edge }` envelope the server sends for every edge
    /// event, so a test states the frame it means rather than the JSON.
    private static func edgeFrame(
        id: String,
        type: String,
        edge: Edge
    ) throws -> SSEEvent {
        struct Frame: Encodable {
            let type: String
            let edge: Edge
        }
        let data = try JSONEncoder().encode(Frame(type: type, edge: edge))
        return SSEEvent(id: id, event: type, data: String(decoding: data, as: UTF8.self))
    }

    @Test("an edge edited elsewhere replaces the stored row and is announced")
    func edgeUpdatedAppliesToAStoredEdge() async throws {
        let (store, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()

        let stored = try await store.createEdge(
            source: "source-1", target: "target-1",
            edgeType: "contains", properties: ["position": .int(1)]
        )

        // The server's copy of the same edge, one edit later.
        let edited = Edge(
            createdAt: stored.createdAt,
            edgeType: stored.edgeType,
            id: stored.id,
            properties: ["position": .int(2)],
            sourceId: stored.sourceId,
            spaceId: stored.spaceId,
            targetId: stored.targetId,
            updatedAt: "2026-09-02T09:00:00.000Z"
        )

        // Subscribe first: a subscription taken afterwards would have missed
        // the emission, and the absence would look like the defect this test
        // is about.
        let events = engine.events
        await engine._applyEventForTesting(
            try Self.edgeFrame(id: "evt-edge-updated", type: "edge.updated", edge: edited)
        )

        let row = try await store.fetchEdge(id: stored.id)
        #expect(row.properties["position"] == .int(2))
        #expect(row.updatedAt == "2026-09-02T09:00:00.000Z")

        let published = await SyncEngineTestKit.publishedEvents(from: events, closing: engine)
        guard case let .edgeUpdated(id) = published.first else {
            Issue.record("expected .edgeUpdated, got \(published)")
            return
        }
        #expect(id == stored.id)
    }

    @Test("an edge edited elsewhere arrives whole on a device that missed its create")
    func edgeUpdatedStoresAnUnknownEdge() async throws {
        let (store, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()

        // No local row for this id: the create landed before this device's
        // cursor, so the edit is the first it hears of the edge. The frame
        // carries the whole edge, so there is nothing to fetch.
        let unseen = Edge(
            createdAt: "2026-09-02T08:00:00.000Z",
            edgeType: "contains",
            id: "edge-never-seen",
            properties: ["position": .int(7)],
            sourceId: "source-2",
            spaceId: nil,
            targetId: "target-2",
            updatedAt: "2026-09-02T09:00:00.000Z"
        )

        let events = engine.events
        await engine._applyEventForTesting(
            try Self.edgeFrame(id: "evt-edge-updated-unknown", type: "edge.updated", edge: unseen)
        )

        let row = try await store.fetchEdge(id: "edge-never-seen")
        #expect(row.properties["position"] == .int(7))
        #expect(row.sourceId == "source-2")
        #expect(row.targetId == "target-2")
        #expect(row.edgeType == "contains")

        let published = await SyncEngineTestKit.publishedEvents(from: events, closing: engine)
        guard case let .edgeUpdated(id) = published.first else {
            Issue.record("expected .edgeUpdated, got \(published)")
            return
        }
        #expect(id == "edge-never-seen")
    }
}
