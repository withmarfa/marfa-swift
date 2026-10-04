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
        let refusal = Refusal(
            reason: "validation_error", fields: [FieldRefusal(field: "title", message: "too long")],
            grant: MissingGrant(kind: .type, name: "core.note", level: .write))
        switch Verdict.refused(refusal) {
        case .refused(let read): #expect(read.fields.map(\.field) == ["title"])
        default: Issue.record("a refusal read as another verdict")
        }
        let kept = QueuedWrite(
            id: "q", kind: .createItem, idempotencyKey: "k", verdict: .refused(refusal), body: ["title": "x"],
            queuedAt: "")
        #expect(kept.body["title"] == "x")
        #expect(QueuedWrite(id: "w", kind: .addTag, idempotencyKey: "k", waiting: true, queuedAt: "").waiting)
        let edgeAnswer = DrainVerdict(id: "q", kind: .createEdge, itemId: "a", edgeId: "e", verdict: .accepted)
        #expect(Change.Origin.answered(edgeAnswer) != .refreshed(.drained))
        #expect(exhaustive(.dead, .refreshed(.catalog), .noCatalog(message: "m")) == 3)

        let report = DrainReport(
            answered: 1, verdicts: [DrainVerdict(id: "q", kind: .createItem, verdict: .merged(fields: ["body"]))])
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
        #expect(UnregisteredType(id: "app.no", code: "forbidden", message: "m").code == "forbidden")
        #expect(MarfaError.canceled(message: "m").code() == "canceled")
        #expect(MarfaError.closed(message: "m").code() == "closed")
        #expect(PinReport(pinned: true, wasPinned: false).pinned)
        #expect(ListFilters(state: .archived, tier: .feed).state == .archived)
        #expect(SearchFilters(state: .trashed).state == .trashed)
        #expect(Draft(type: "core.note", tier: .library).tier == .library)
        let field = TypeField(name: "title", type: "string", declaredBy: "core.note")
        #expect(ItemType(id: "core.note", fields: [field]).fields.map(\.id) == ["title"])
        let edgeType = EdgeType(
            id: "parent-of", cardinality: "one-to-many", reverseName: "child-of", writtenAt: .target)
        #expect(edgeType.writtenAt == .target)
        #expect(Status(catalogVersion: 2).catalogVersion == 2)
        #expect(Change.Refresh.catalog != .hydrated)
    }
}

#if os(macOS)
/// A Mac app's previews make folder values with only `Marfa` imported.
@Test func anAppMakesItsOwnFolderValues() {
    let listed = ListedFolder(directory: URL(filePath: "/Notes", directoryHint: .isDirectory), folderId: "f")
    #expect(listed.folderId == "f")
    let status = FolderStatus(
        files: [FileStatus(path: "a.md", state: .waiting, waits: ["create"])], paused: PausedRemoval(disk: 2),
        firstSync: WaitingFirstSync(plan: FirstSyncPlan(write: 1, send: 2, beside: 0)))
    #expect(status.firstSync?.plan?.send == 2)
    #expect(status.paused.isPaused)
    #expect(!PausedRemoval().isPaused)
    let read: Bool =
        switch status.files[0].state {
        case .inStep, .waiting, .held, .unmatched, .unreached, .outside: true
        }
    #expect(read)
    let sync = FolderSyncResult.awaitingConfirmation(FirstSyncPlan(write: 1, send: 2, beside: 0))
    let syncRead: Bool =
        switch sync {
        case .synced, .awaitingConfirmation: true
        }
    #expect(syncRead)
    let event = FolderEvent.retrying(.network(message: "m"), after: .seconds(1))
    let told: Bool =
        switch event {
        case .watching, .watcherFailed, .retrying, .unreachable, .reachable, .waiting, .passed: true
        }
    #expect(told)
}
#endif

/// Compiles only while these switches are exhaustive with no `@unknown
/// default`, as the README tells apps to write them.
private func exhaustive(_ verdict: Verdict, _ origin: Change.Origin, _ error: MarfaError) -> Int {
    let verdictRead: Bool =
        switch verdict {
        case .accepted, .merged, .conflicted, .refused, .blocked, .dead: true
        }
    let originRead: Bool =
        switch origin {
        case .local, .server, .answered, .saved, .refreshed, .stopped: true
        }
    let errorRead: Bool =
        switch error {
        case .notFound, .unauthorized, .forbidden, .validation, .unknownType, .rateLimited, .server, .io, .network,
            .unnamed, .decoding, .store, .storageFull, .signedOut, .noKeychain, .redirected, .noServer, .noCursor,
            .hydrationIncomplete, .noCatalog, .wrongSchema,
            .readingHandle,
            .copyExpired, .streamIncomplete, .wrongServer, .bytesAbsent, .contractMismatch, .canceled,
            .firstSyncWaiting, .invalid,
            .closed:
            true
        }
    return [verdictRead, originRead, errorRead].filter { $0 }.count
}
