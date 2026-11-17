import Foundation
import MarfaCore
import MarfaTypes
import Synchronization
import Testing

@testable import Marfa

/// A core whose counts, and the tables its catch-up changed, a test scripts.
private final class CountingCore: Core, @unchecked Sendable {
    private let state = Mutex((asked: [[String]](), refuses: false, tables: [MarfaCore.ChangedTable]()))

    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("a fake core has no handle") }

    var asked: [[String]] { state.withLock { $0.asked } }
    func refuseCounts() { state.withLock { $0.refuses = true } }
    func changeTables(_ tables: [MarfaCore.ChangedTable]) { state.withLock { $0.tables = tables } }

    override func heldHandle() -> MarfaCore.Handle { .writer }

    override func status() throws -> MarfaCore.Status { emptyStatus() }

    override func counts(ids: [String], counted: MarfaCore.Counted) throws -> [MarfaCore.ItemCount] {
        let refuses = state.withLock { state -> Bool in
            state.asked.append(ids)
            return state.refuses
        }
        if refuses { throw MarfaCore.MarfaError.Invalid(message: "the copy may lack an item the server counts") }
        return ids.map {
            MarfaCore.ItemCount(
                id: $0, total: 7,
                statusGroups: MarfaCore.StatusGroups(notStarted: 1, inProgress: 2, completed: 3, canceled: 1),
                held: true)
        }
    }

    override func changesSince(cursor: String?, most: UInt32) throws -> MarfaCore.CopyChanges {
        MarfaCore.CopyChanges(
            cursor: "2", everything: false, items: [], removedItems: [], edges: [], removedEdges: [],
            tables: state.withLock { $0.tables })
    }

    override func catchUp(stop: MarfaCore.Stop?) throws -> MarfaCore.CatchUpReport {
        MarfaCore.CatchUpReport(
            applied: 0, skipped: 0, readOnlyHeld: 0, cursor: "1", catalogChanged: false,
            changedTables: state.withLock { $0.tables })
    }
}

@Suite(.timeLimit(.minutes(1)))
struct Counts {
    private let counted = Marfa.Counted.backref(edgeType: "parent-of")

    private func serverCounting() async throws -> LocalServer {
        try await LocalServer.start(contract: marfaContractVersion) { method, path in
            guard (method, path) == ("POST", "/items/counts") else { return LocalServer.emptyPage(method, path) }
            return (
                200, "application/json",
                #"{"counts":[{"id":"a","total":4,"status_groups":{"not_started":1,"in_progress":0,"completed":2,"canceled":1}}]}"#
            )
        }
    }

    @Test func theCopyAnswersWhereItCanBeSureAndSaysSo() async throws {
        let core = CountingCore()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let counts: [Marfa.ItemCount] = try await copy.counts(of: ["a", "b"], counted)
        #expect(counts.map { $0.id } == ["a", "b"] && counts.allSatisfy { $0.held })
        #expect(counts[0].total == 7)
        let groups = Marfa.StatusGroupCounts(notStarted: 1, inProgress: 2, completed: 3, canceled: 1)
        #expect(counts[0].statusGroups == groups)
        await copy.close()
    }

    @Test func moreThanAHundredIdsGoInBatchesAndARepeatedIdIsAskedOnce() async throws {
        let core = CountingCore()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let ids = (0..<150).map { "item-\($0)" }
        let counts: [Marfa.ItemCount] = try await copy.counts(of: ids + ["item-0"], counted)
        #expect(counts.map { $0.id } == ids)
        #expect(core.asked.map { $0.count } == [100, 50])
        await copy.close()
    }

    @Test func aRefusalByTheCopyIsAskedOfTheServer() async throws {
        let core = CountingCore()
        core.refuseCounts()
        let server = try await serverCounting()
        defer { server.stop() }
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let asked = Server(url: server.url, key: "k")
        let counts: [Marfa.ItemCount] = try await copy.counts(of: ["a"], counted, server: asked)
        #expect(counts.count == 1 && !counts[0].held && counts[0].total == 4)
        #expect(counts[0].statusGroups?[.completed] == 2 && counts[0].statusGroups?[.canceled] == 1)
        #expect(server.log.all.contains { $0.hasPrefix("POST /items/counts ") })
        await copy.close()
    }

    @Test func noCountIsAnErrorNeverAZero() async throws {
        let core = CountingCore()
        core.refuseCounts()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        // Refused by the copy, with no server to ask.
        await #expect(throws: CountError.self) { try await copy.counts(of: ["a"], counted) }

        // Refused by the copy, with a server that cannot be reached.
        let gone = try await serverCounting()
        let url = gone.url
        gone.stop()
        await #expect(throws: CountError.self) {
            try await copy.counts(of: ["a"], counted, server: Server(url: url, key: "k"))
        }
        await copy.close()
    }

    @Test func aCatchUpNamesTheTablesItChangedAndTellsTheStreams() async throws {
        let core = CountingCore()
        core.changeTables([MarfaCore.ChangedTable(itemId: "item", table: "messages")])
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let heard = Heard(copy.changes())
        let report = try await copy.catchUp()
        #expect(report.changedTables == [ChangedTable(itemId: "item", table: "messages")])
        try await eventually("the table change is told") {
            heard.all.contains { $0.origin == .refreshed(.tables) }
        }
        heard.stop()

        guard case .named(let rows, _) = try await copy.changes(since: nil) else {
            Issue.record("expected named changes")
            return
        }
        #expect(rows.tables == report.changedTables && !rows.isEmpty)
        await copy.close()
    }
}
