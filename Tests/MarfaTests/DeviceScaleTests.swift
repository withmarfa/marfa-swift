import Foundation
import MarfaCore
import Synchronization
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct EveryTypeHydration {
    @Test func theEveryTypeSliceReachesTheCoreAsGiven() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        for types in [["*"], ["*", "system.view"]] {
            _ = try await copy.hydrate(types: types, tier: .all)
            #expect(core.state.withLock { $0.hydrationOptions?.types } == types)
        }
        await copy.close()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct RefillInPlace {
    @Test func theReportSaysWhetherTheCopyWasFilledAgainOverTheRowsItHeld() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        #expect(try await copy.hydrate(types: ["*"], tier: .all).inPlace == false)
        core.state.withLock { $0.hydrateInPlace = true }
        #expect(try await copy.hydrate(types: ["*"], tier: .all).inPlace)
        await copy.close()
    }

    @Test func aStaleCopyIsStaleInItsStatus() async throws {
        let core = FakeCore.writer()
        core.state.withLock { $0.hydration = .stale }
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        #expect(try await copy.status().hydration == .stale)
        #expect(Marfa.Hydration.allCases.contains(.stale))
        await copy.close()
    }

    @Test func anEdgeWriteDuringAFillIsRefusedAsIncompleteAndQueuesNothing() async throws {
        let core = FakeCore.writer()
        core.state.withLock { $0.edgeWriteFails = .HydrationIncomplete(message: "still filling") }
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let heard = Heard(copy.changes())
        await #expect(throws: Marfa.MarfaError.hydrationIncomplete(message: "still filling")) {
            _ = try await copy.edges.create(from: "a", to: "b", type: "core.link")
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(heard.all.isEmpty, "a refused write announced \(heard.all)")
        await copy.close()
    }

    @Test func aCatchUpOfAStaleCopyNamesWhyItIsRefused() async throws {
        let core = FakeCore.writer()
        let failure = MarfaCore.MarfaError.CopyExpired(reason: "catchup_too_old", message: "refill the copy")
        core.state.withLock { $0.catchUpFails = failure }
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        await #expect(throws: Marfa.MarfaError.copyExpired(reason: "catchup_too_old", message: "refill the copy")) {
            _ = try await copy.catchUp()
        }
        await copy.close()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AFillThatEnds {
    @Test func aFillThatFailsPartWayAnnouncesThatTheRowsChanged() async throws {
        let core = FakeCore.writer()
        core.state.withLock { $0.hydrateFails = .Network(message: "the connection dropped") }
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let heard = Heard(copy.changes())
        await #expect(throws: Marfa.MarfaError.network(message: "the connection dropped")) {
            _ = try await copy.hydrate(types: ["*"], tier: .all)
        }
        try await eventually("the failed fill was announced") { heard.all == [Self.unfinished] }
        await copy.close()
    }

    @Test func aFillThatIsCanceledAnnouncesThatTheRowsChanged() async throws {
        let core = FakeCore.writer()
        core.state.withLock { $0.hydrateFails = .Canceled(message: "stopped") }
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let heard = Heard(copy.changes())
        await #expect(throws: Marfa.MarfaError.canceled(message: "stopped")) {
            _ = try await copy.hydrate(types: ["*"], tier: .all)
        }
        try await eventually("the canceled fill was announced") { heard.all == [Self.unfinished] }
        await copy.close()
    }

    @Test func aFillThatSucceedsAnnouncesOnceAndASuccessStillDoes() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let heard = Heard(copy.changes())
        _ = try await copy.hydrate(types: ["*"], tier: .all)
        try await eventually("the fill was announced") { !heard.all.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(heard.all == [Self.hydrated])
        await copy.close()
    }

    @MainActor @Test func aLiveQueryLeavesItsPartialSnapshotWhenTheFillFails() async throws {
        let core = FillingFailureCore()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let query = LiveQuery(copy, reading: Reading<Rows<Marfa.Item>>.list())
        await query.refresh()
        #expect(query.value.completeness == .partial)
        core.finish()
        let heard = Heard(copy.changes())
        await #expect(throws: Marfa.MarfaError.self) { _ = try await copy.hydrate(types: ["*"], tier: .all) }
        try await eventually("the unfinished fill was announced") { heard.all == [Self.unfinished] }
        try await eventually("the query read the copy again") { query.value.completeness == .stale }
        await copy.close()
    }

    static let hydrated = Marfa.Change(origin: .refreshed(.hydrated), itemId: nil, edgeId: nil)
    static let unfinished = Marfa.Change(origin: .refreshed(.unfinished), itemId: nil, edgeId: nil)
}

/// A core whose list is partial while a fill runs and stale once a failed fill has left the rows it kept.
final class FillingFailureCore: Core, @unchecked Sendable {
    private let finished = Mutex(false)

    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("a fake core has no handle") }

    func finish() { finished.withLock { $0 = true } }

    override func heldHandle() -> MarfaCore.Handle { .writer }

    override func list(filters: MarfaCore.ListFilters, sort: MarfaCore.Sort?) throws -> MarfaCore.Listing {
        Listing(
            items: [],
            completeness: finished.withLock { $0 } ? MarfaCore.Completeness.stale : MarfaCore.Completeness.partial)
    }

    override func hydrateWith(
        types: [String], tier: MarfaCore.SliceTier, edgeTypes: [String], inPlaceOnly: Bool, stop: MarfaCore.Stop?
    ) throws -> MarfaCore.HydrateReport {
        throw MarfaCore.MarfaError.Network(message: "the connection dropped")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct FileBudgetAndKeptAttachments {
    @Test func theBudgetAndTheCacheAreReadAndSetThroughBlobs() async throws {
        let core = FakeCore.writer()
        core.state.withLock { $0.trimmed = 7 }
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)

        #expect(try await copy.blobs.setBudget(.bytes(bytes: 1_000)) == 7)
        #expect(try await copy.blobs.setBudget(.keepAll) == 7)
        #expect(core.state.withLock { $0.budgets } == [.bytes(bytes: 1_000), .keepAll])
        #expect(try await copy.blobs.cache().setting == .keepAll)
        #expect(try await copy.blobs.trim() == 7)
        await copy.close()
    }

    @Test func fetchingTheKeptAttachmentsAnswersWhatItFetchedAndWhatIsLeft() async throws {
        let core = FakeCore.writer()
        let left = Attachments(
            held: 3, heldBytes: 90, partialBytes: 0, notHeld: 2, notHeldBytes: 50,
            notHeldByReason: [
                NotHeld(reason: .noRoom, attachments: 1, bytes: 40, unstated: 0),
                NotHeld(reason: .rateLimited, attachments: 1, bytes: 10, unstated: 1),
            ])
        core.state.withLock { $0.cache.attachments = left }
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)

        let report = try await copy.blobs.fetchKept()
        #expect(report.fetched == 2 && report.fetchedBytes == 30)
        #expect(report.attachments == KeptAttachments(left))
        #expect(try await copy.blobs.cache().attachments?.notHeldByReason.map(\.reason) == [.noRoom, .rateLimited])
        #expect(core.state.withLock { $0.keptFetches } == 1)
        await copy.close()
    }
}

/// The real core, over a store in a temporary folder with no server.
@Suite(.timeLimit(.minutes(1)))
struct FileBudgetOnOpen {
    @Test func aBudgetGivenOnOpenIsInForceAndKeptForTheNextOpen() async throws {
        let store = temporaryStore()
        let first = try await WorkingCopy.open(store: store, fileBudget: .bytes(bytes: 4_096))
        #expect(try await first.status().fileCache.setting == .bytes(bytes: 4_096))
        #expect(try await first.blobs.cache().budget == 4_096)
        #expect(try await first.blobs.cache() == first.status().fileCache)
        await first.close()

        let reopened = try await WorkingCopy.open(store: store)
        #expect(try await reopened.status().fileCache.setting == .bytes(bytes: 4_096), "nil leaves the choice alone")
        _ = try await reopened.blobs.setBudget(.keepAll)
        #expect(try await reopened.blobs.cache().setting == .keepAll)
        #expect(try await reopened.blobs.cache().budget == nil, "no budget is in force while every file is kept")
        await reopened.close()

        let again = try await WorkingCopy.open(store: store)
        #expect(try await again.status().fileCache.setting == .keepAll)
        await again.close()
    }

    @Test func aStoreWithNoChoiceUsesTheDefault() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        #expect(try await copy.status().fileCache.setting == .default)
        let attachments = try #require(try await copy.status().fileCache.attachments)
        #expect(attachments.held == 0 && attachments.notHeld == 0 && attachments.notHeldByReason.isEmpty)
        await copy.close()
    }

    @Test func aReaderCannotSetItAndOpeningWithOneLeavesTheWriterAlone() async throws {
        let store = temporaryStore()
        let writer = try await WorkingCopy.open(store: store)
        await #expect {
            _ = try await WorkingCopy.open(store: store, fileBudget: .keepAll)
        } throws: { error in
            // The second opener of a store is a reader, which the core refuses to change the budget.
            if case .readingHandle? = error as? Marfa.MarfaError { true } else { false }
        }
        #expect(try await writer.status().fileCache.setting == .default)
        await #expect { _ = try await writer.blobs.fetchKept() } throws: { error in
            if case .noServer? = error as? Marfa.MarfaError { true } else { false }
        }
        await writer.close()
    }

    @Test func aReaderRefusesToTrimOrFetch() async throws {
        let store = temporaryStore()
        let writer = try await WorkingCopy.open(store: store)
        let reader = try await WorkingCopy.openReader(store: store)
        for call in [
            { _ = try await reader.blobs.setBudget(.keepAll) }, { _ = try await reader.blobs.trim() },
            { _ = try await reader.blobs.fetchKept() },
        ] as [@Sendable () async throws -> Void] {
            await #expect {
                try await call()
            } throws: { error in
                if case .readingHandle? = error as? Marfa.MarfaError { true } else { false }
            }
        }
        await reader.close()
        await writer.close()
    }
}
