import Foundation
import Marfa
import Testing

/// What an app can reach with a plain import, as an app's previews and tests
/// do: the core's vocabulary has to be constructible without the package's
/// testing access.
@Suite struct PublicSurface {
    @Test func anAppMakesItsOwnItemsAndEdges() {
        let item = Item(
            id: "item", type: "core.note", properties: ["body": "text"], state: .active, tier: .library,
            version: 3, schemaVersion: 1, source: "app", sourceId: nil, occurredAt: "2026-09-26T00:00:00.000Z",
            createdAt: "2026-09-26T00:00:00.000Z", updatedAt: "2026-09-26T00:00:00.000Z", tags: ["favorite"])
        #expect(item.properties["body"]?.string == "text")
        #expect(item.version == 3)

        let edge = Edge(
            id: "edge", sourceId: "reply", targetId: "item", edgeType: "in-thread", properties: ["position": 1],
            version: 1, createdAt: "2026-09-26T00:00:00.000Z", updatedAt: "2026-09-26T00:00:00.000Z")
        #expect(edge.targetId == "item")
    }
}
