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
        #expect(item.title == nil)
        let titled = Item(
            id: "item", type: "core.event", properties: ["title": "Standup", "description": "Daily"], state: .active,
            tier: .library, version: 1, schemaVersion: 1, source: "app", sourceId: nil,
            occurredAt: "2026-09-26T00:00:00.000Z", createdAt: "2026-09-26T00:00:00.000Z",
            updatedAt: "2026-09-26T00:00:00.000Z", tags: [], title: "Standup", body: "Daily")
        #expect(titled.body == "Daily")
        let edits = [
            Edit(properties: ["title": "a"], baseVersion: 1),
            Edit(properties: ["body": "b"], replaceProperties: true, baseVersion: 1),
            Edit(baseVersion: 1, type: "core.task", tier: .feed),
        ]
        #expect(Set(edits).count == 3)
        let moves = [
            EdgeEdit(baseVersion: 1), EdgeEdit(["note": "x"], baseVersion: 1),
            EdgeEdit(baseVersion: 1, move: .source("a")), EdgeEdit(baseVersion: 1, move: .target("a")),
        ]
        #expect(Set(moves).count == 4)

        let edge = Edge(
            id: "edge", sourceId: "reply", targetId: "item", edgeType: "in-thread", properties: ["position": 1],
            version: 1, createdAt: "2026-09-26T00:00:00.000Z", updatedAt: "2026-09-26T00:00:00.000Z")
        #expect(edge.targetId == "item")
    }

    @MainActor @Test func anAppReadsThroughAQueryAndOwnsItsReadings() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let notes = LiveQuery(copy, reading: .list(ListFilters(type: "core.note"), sort: nil))
        let queued = LiveQuery(copy, reading: Reading(placeholder: 0) { try await $0.queue.all().count })
        #expect(notes.copy === copy && notes.value.isEmpty && notes.isLoading && notes.error == nil)
        #expect(notes.following == .live)
        #expect(
            Set([Following.live, .stopped(.network(message: "away")), .ended(nil), .ended(.closed(message: "m"))]).count
                == 4)
        notes.reading = .search("marmalade", filters: SearchFilters(type: "core.note"), limit: 5)
        await notes.refresh()
        await queued.refresh()
        #expect(queued.value == 0)
        await copy.close()
    }

    /// The labels in the order the package has always taken them, since a call
    /// that names them in another order does not compile.
    @Test func theRecordsTheCoreDefinesTakeTheirLabelsInTheOrderTheyAlwaysDid() {
        let search = SearchFilters(type: "core.note", state: .archived)
        #expect(search.type == "core.note" && search.state == .archived)
        let everywhere = SearchFilters(type: "core.note", allStates: true, tags: ["a"], filter: "x", beneath: "r")
        #expect(everywhere.allStates && everywhere.tags == ["a"] && everywhere.beneath == "r")
        let list = ListFilters(
            type: "core.note", state: .active, allStates: false, tier: .feed, tags: ["a"], occurredAfter: "a",
            occurredBefore: "b", filter: "f", beneath: "r", limit: 5, offset: 1)
        #expect(list.limit == 5 && list.offset == 1 && list.tier == .feed)
        let draft = Draft(
            type: "core.note", properties: ["title": "t"], tags: ["a"], tier: .feed, id: "i", source: "s",
            sourceId: "k", occurredAt: "o", baseVersion: 2)
        #expect(draft.baseVersion == 2 && draft.sourceId == "k")
        let page = BinPage(items: [], nextCursor: "c")
        #expect(page.nextCursor == "c")
        let edit = Edit(
            properties: ["a": 1], replaceProperties: true, baseVersion: 3, sourceId: "k", type: "t", tier: .library)
        #expect(edit.replaceProperties && edit.baseVersion == 3)
    }

    /// Each enum's cases as default arguments, and each value type made, with
    /// only `Marfa` imported: none of it names the glue.
    @Test func anAppUsesEveryValueTypeAsItsOwn() {
        func placing(
            tier: Tier = .library, state: ItemState = .active, kind: WriteKind = .createItem,
            blocked: BlockedReason = .credentialRefused, handle: Handle = .writer,
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
        #expect(Verdict.blocked(reason: .keySpent) != .blocked(reason: .credentialRefused))
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
        #expect(CatchUpReport(applied: 1, skipped: 0, cursor: "1").cursor == "1")
        let hydrated = HydrateReport(
            types: ["core.note"], tier: .library, edgeTypes: [], items: 1, edges: 0, pages: 1, cursor: "1")
        #expect(hydrated.tier == .library)
        #expect(Status(sliceTier: .all).sliceTier == .all)
        #expect(Tier.allCases.map(SliceTier.init) == [.library, .feed])
        #expect(SliceTier.allCases.count == 3)
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
        #expect(EdgeType(id: "in-folder", cardinality: "many-to-many", writtenAt: .none).writtenAt == .none)
        #expect(Status(catalogVersion: 2).catalogVersion == 2)
        #expect(Change.Refresh.catalog != .hydrated)
        #expect(Change.Origin.serverUnreachable(.network(message: "m")) != .serverReachable)
        #expect(Change.Refresh.purged != .unpinned)
        #expect(Change.Refresh.forgotten != .withdrawn)
    }
}

#if os(macOS)
/// A Mac app's previews make folder values with only `Marfa` imported.
@Test func anAppMakesItsOwnFolderValues() {
    let listed = ListedFolder(directory: URL(filePath: "/Notes", directoryHint: .isDirectory), folderId: "f")
    #expect(listed.folderId == "f")
    let added = AddedFolder(
        directory: URL(filePath: "/Notes", directoryHint: .isDirectory), folderId: "f", storage: .cloudSynced)
    #expect(added.storage == .cloudSynced)
    let cause: Bool =
        switch StorageCause.networkFileSystem(kind: "nfs") {
        case .iCloudDrive, .cloudService, .cloudSynced, .networkFileSystem: true
        }
    #expect(cause)
    let status = FolderStatus(
        files: [FileStatus(path: "a.md", state: .waiting, waits: ["create"])], paused: PausedRemoval(disk: 2),
        firstSync: WaitingFirstSync(plan: FirstSyncPlan(write: 1, send: 2, beside: 0, left: 0)))
    #expect(status.firstSync?.plan?.send == 2)
    #expect(status.paused.isPaused)
    #expect(!PausedRemoval().isPaused)
    let read: Bool =
        switch status.files[0].state {
        case .inStep, .waiting, .held, .unmatched, .unreached, .outside: true
        }
    #expect(read)
    let sync = FolderSyncResult.awaitingConfirmation(FirstSyncPlan(write: 1, send: 2, beside: 0, left: 0))
    let syncRead: Bool =
        switch sync {
        case .synced, .awaitingConfirmation: true
        }
    #expect(syncRead)
    let event = FolderEvent.retrying(.network(message: "m"), after: .seconds(1))
    let told: Bool =
        switch event {
        case .watching, .watcherFailed, .retrying, .unreachable, .reachable, .waiting, .passed, .handedOver,
            .heldElsewhere, .takenBack, .removed, .unlisted:
            true
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
        case .local, .server, .serverUnreachable, .serverReachable, .queueDrained, .queueNotDrained, .answered, .saved,
            .refreshed, .stopped:
            true
        }
    let errorRead: Bool =
        switch error {
        case .notFound, .unauthorized, .forbidden, .validation, .unknownType, .rateLimited, .server, .io, .network,
            .unnamed, .decoding, .store, .storageFull, .signedOut, .noKeychain, .redirected, .noServer, .noCursor,
            .hydrationIncomplete, .noCatalog, .wrongSchema,
            .readingHandle,
            .copyExpired, .streamIncomplete, .wrongServer, .bytesAbsent, .noRoom, .contractMismatch, .canceled,
            .firstSyncWaiting, .invalid,
            .closed:
            true
        }
    return [verdictRead, originRead, errorRead].filter { $0 }.count
}

/// The sign-in surface as an app sees it, without `@testable`.
@Suite struct PublicSignIn {
    @Test func anAppDescribesItselfAndChoosesWhereItsSignInIsKept() throws {
        let client = Authorization.Client(
            name: "Notes", redirect: URL(string: "com.example.notes:/signed-in"), scopes: ["core.note:read"])
        let authorization = try Authorization(
            server: try #require(URL(string: "https://Marfa.Example:443/some/path")), client: client,
            keychain: Keychain(accessGroup: "ABCDE12345.com.example.notes"), service: "com.example.notes")
        #expect(authorization.server.absoluteString == "https://marfa.example")
        #expect(authorization.client == client)
        #expect(Keychain(accessGroup: "a") == Keychain(accessGroup: "a"))
        #expect(Keychain(accessGroup: "a") != Keychain.system)
        let errors: [SignInError] = [
            .canceled, .denied, .expired, .stateMismatch, .notSignedIn, .notAServer, .otherServer, .noRedirect,
            .refused(code: "invalid_scope", message: "m"),
            .unavailable(message: "offline"), .unreadable(message: "unreadable"),
        ]
        #expect(Set(errors.map(\.description)).count == errors.count)
    }
}
