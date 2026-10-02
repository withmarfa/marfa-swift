import Foundation
import Marfa
import Testing

/// A plain import, without `@testable`, as an app's previews and tests use.
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

    /// Each enum's cases as default arguments, and each value type made, with
    /// only `Marfa` imported: none of it names the glue.
    @Test func anAppUsesEveryValueTypeAsItsOwn() {
        func placing(
            tier: Tier = .library, state: ItemState = .active, kind: WriteKind = .createItem,
            blocked: BlockedReason = .awaitingDependency, handle: Handle = .writer,
            hydration: Hydration = .never, field: SortField = .updatedAt,
            direction: SortDirection = .ascending, verdict: Verdict = .accepted
        ) -> [any Sendable] {
            [tier, state, kind, blocked, handle, hydration, field, direction, verdict]
        }
        #expect(placing().count == 9)

        let write = QueuedWrite(id: "q", kind: .addTag, itemId: "item", idempotencyKey: "k", queuedAt: "")
        #expect(write.verdict == nil)
        let answered = QueuedWrite(
            id: "q", kind: .updateItem, idempotencyKey: "k",
            verdict: .conflicted(siblingId: "s", fields: ["title"]), queuedAt: "")
        #expect(answered.verdict == .conflicted(siblingId: "s", fields: ["title"]))
        #expect(Verdict.blocked(reason: .keySpent) != .blocked(reason: .awaitingDependency))

        let report = DrainReport(
            sent: 1, verdicts: [DrainVerdict(id: "q", kind: .createItem, verdict: .merged(fields: ["body"]))])
        #expect(report.verdicts.count == 1)
        #expect(Sort(field: .createdAt, direction: .descending).direction == .descending)
        #expect(Status(sliceTier: .feed, hydration: .complete).hydration == .complete)
        #expect(Attachment(tier: .feed).tier == .feed)
        #expect(Attached(upload: write, item: write, edge: write).edge == write)
        #expect(Thumbnail(mimeType: "image/png", bytes: Data()).mimeType == "image/png")
        #expect(CatchUpReport(applied: 1, skipped: 0, cursor: "1", reachedHead: true).reachedHead)
        let hydrated = HydrateReport(
            types: ["core.note"], tier: .library, edgeTypes: [], items: 1, edges: 0, pages: 1, cursor: "1")
        #expect(hydrated.tier == .library)
        #expect(ListFilters(state: .archived, tier: .feed).state == .archived)
        #expect(SearchFilters(state: .trashed).state == .trashed)
        #expect(Draft(type: "core.note", tier: .library).tier == .library)
    }
}
