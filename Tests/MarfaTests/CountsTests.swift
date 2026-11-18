import Foundation
import MarfaCore
import MarfaTypes
import Synchronization
import Testing

@testable import Marfa

/// A core whose counts, its answers from the server, and the tables its catch-up changed, a test scripts.
private final class CountingCore: Core, @unchecked Sendable {
    struct Script {
        var asked: [[String]] = []
        var served: [[String]] = []
        /// What the copy's own count throws; `NotAnswerable` sends the count to the server.
        var refusal: MarfaCore.MarfaError?
        /// What asking the server throws.
        var servedFailure: MarfaCore.MarfaError?
        var tables: [MarfaCore.ChangedTable] = []
        var servedAnswers = 0
        var watchers: [any MarfaCore.ChangeListener] = []
        var watchesStopped = 0
    }

    private let state = Mutex(Script())
    /// Holds each answer from the server until it is signaled, where set.
    let servedGate: DispatchSemaphore?

    init(servedGate: DispatchSemaphore? = nil) {
        self.servedGate = servedGate
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("a fake core has no handle") }

    var asked: [[String]] { state.withLock { $0.asked } }
    var served: [[String]] { state.withLock { $0.served } }
    /// How many answers from the server got past the gate.
    var servedAnswers: Int { state.withLock { $0.servedAnswers } }
    var watching: Int { state.withLock { $0.watchers.count } }
    var watchesStopped: Int { state.withLock { $0.watchesStopped } }
    func refuseCounts(_ refusal: MarfaCore.MarfaError = .NotAnswerable(message: "the copy may lack an item")) {
        state.withLock { $0.refusal = refusal }
    }
    func failServed(_ failure: MarfaCore.MarfaError) { state.withLock { $0.servedFailure = failure } }
    func changeTables(_ tables: [MarfaCore.ChangedTable]) { state.withLock { $0.tables = tables } }

    override func heldHandle() -> MarfaCore.Handle { .writer }

    override func status() throws -> MarfaCore.Status { emptyStatus() }

    override func counts(ids: [String], counted: MarfaCore.Counted) throws -> [MarfaCore.ItemCount] {
        let refusal = state.withLock { state in
            state.asked.append(ids)
            return state.refusal
        }
        if let refusal { throw refusal }
        return ids.map {
            MarfaCore.ItemCount(
                id: $0, total: 7,
                statusGroups: MarfaCore.StatusGroups(notStarted: 1, inProgress: 2, completed: 3, canceled: 1),
                held: true)
        }
    }

    override func servedCounts(ids: [String], counted: MarfaCore.Counted) throws -> [MarfaCore.ItemCount] {
        let failure = state.withLock { state in
            state.served.append(ids)
            return state.servedFailure
        }
        servedGate?.wait()
        state.withLock { $0.servedAnswers += 1 }
        if let failure { throw failure }
        return ids.map {
            MarfaCore.ItemCount(
                id: $0, total: 4,
                statusGroups: MarfaCore.StatusGroups(notStarted: 1, inProgress: 0, completed: 2, canceled: 1),
                held: false)
        }
    }

    /// A watch the core lets go of only once the test ends it, so a feed letting go of the store waits.
    override func watch(toldUnreachable: Bool, listener: any MarfaCore.ChangeListener) throws -> MarfaCore.Subscription
    {
        state.withLock { $0.watchers.append(listener) }
        return FakeSubscription { [self] in state.withLock { $0.watchesStopped += 1 } }
    }

    func endWatches() {
        for listener in state.withLock({ $0.watchers.drain() }) { listener.ended(error: nil) }
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

    /// A server that answers every `POST /items/counts` with `body`.
    private func serverAnswering(_ body: String) async throws -> LocalServer {
        try await LocalServer.start(contract: marfaContractVersion) { method, path in
            guard (method, path) == ("POST", "/items/counts") else { return LocalServer.emptyPage(method, path) }
            return (200, "application/json", body)
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
        #expect(core.served.isEmpty)
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

    @Test func aCountTheCopyCannotAnswerIsAskedOfItsOwnServerBatchByBatch() async throws {
        let core = CountingCore()
        core.refuseCounts()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let ids = (0..<150).map { "item-\($0)" }
        let counts: [Marfa.ItemCount] = try await copy.counts(of: ids, counted)
        #expect(counts.map { $0.id } == ids && counts.allSatisfy { !$0.held && $0.total == 4 })
        #expect(counts[0].statusGroups?[.completed] == 2 && counts[0].statusGroups?[.canceled] == 1)
        #expect(core.served.map { $0.count } == [100, 50])
        await copy.close()
    }

    @Test func onlyACountTheCopyCannotAnswerIsAskedOfTheServer() async throws {
        let core = CountingCore()
        core.refuseCounts(.Invalid(message: "the renewal failed"))
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        await #expect(throws: Marfa.MarfaError.invalid(message: "the renewal failed")) {
            try await copy.counts(of: ["a"], counted)
        }
        #expect(core.asked == [["a"]] && core.served.isEmpty)
        await copy.close()
    }

    @Test(arguments: [50, 150])
    func noCountAnsweredUnderAKeyBeingReplacedIsReturned(asking: Int) async throws {
        let gate = DispatchSemaphore(value: 0)
        let old = CountingCore(servedGate: gate)
        old.refuseCounts()
        let new = CountingCore()
        let copy = WorkingCopy(holder: CoreHolder(old, reopen: { _ in new }), hasServer: false)
        let ids = (0..<asking).map { "item-\($0)" }
        let counting = Task { try await copy.counts(of: ids, counted) }
        try await eventually("the first batch is asked of the server") { old.served.count == 1 }
        let changing = Task { try await copy.useKey("new-key") }
        try await eventually("the key is changing") {
            do {
                _ = try await copy.status()
                return false
            } catch Marfa.MarfaError.keyChanging {
                return true
            }
        }
        gate.signal()
        try await changing.value
        let counts = try await counting.value
        #expect(counts.map(\.id) == ids && counts.allSatisfy { $0.held && $0.total == 7 })
        #expect(old.served.count == 1)
        await copy.close()
    }

    /// `useKey` waits for the feed to let go of the store before the holder starts replacing the core.
    @Test func aCountAnsweredOnceUseKeyBeganIsAskedAgainUnderTheNewKey() async throws {
        let gate = DispatchSemaphore(value: 0)
        let old = CountingCore(servedGate: gate)
        old.refuseCounts()
        let new = CountingCore()
        let copy = WorkingCopy(holder: CoreHolder(old, reopen: { _ in new }), hasServer: true)
        let stream = Heard(copy.changes())
        try await eventually("the stream is in the watch") { old.watching == 1 }
        let counting = Task { try await copy.counts(of: ["a"], counted) }
        let finished = Mutex(false)
        Task {
            _ = try? await counting.value
            finished.withLock { $0 = true }
        }
        try await eventually("the count is asked of the server") { old.served.count == 1 }
        let changing = Task { try await copy.useKey("new-key") }
        try await eventually("the feed is letting go of the store") { old.watchesStopped == 1 }
        gate.signal()
        try await eventually("the server answered") { old.servedAnswers == 1 }
        // The old answer must not be returned while the key change waits on the feed.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!finished.withLock { $0 })
        old.endWatches()
        try await changing.value
        let counts = try await counting.value
        #expect(counts.map(\.id) == ["a"] && counts.allSatisfy { $0.held && $0.total == 7 })
        #expect(new.asked == [["a"]])
        stream.stop()
        try await eventually("the new core's watch is stopped") { new.watchesStopped == 1 }
        new.endWatches()
        await copy.close()
    }

    @Test func aCountInFlightWhenTheReopenFailsThrowsClosed() async throws {
        let gate = DispatchSemaphore(value: 0)
        let old = CountingCore(servedGate: gate)
        old.refuseCounts()
        let copy = WorkingCopy(
            holder: CoreHolder(old, reopen: { _ in throw MarfaCore.MarfaError.Io(message: "the store is gone") }),
            hasServer: false)
        let counting = Task { try await copy.counts(of: ["a"], counted) }
        try await eventually("the count is asked of the server") { old.served.count == 1 }
        let changing = Task { try await copy.useKey("new-key") }
        try await eventually("the key is changing") {
            do {
                _ = try await copy.status()
                return false
            } catch Marfa.MarfaError.keyChanging {
                return true
            }
        }
        gate.signal()
        await #expect(throws: Marfa.MarfaError.self) { try await changing.value }
        await #expect(throws: Marfa.MarfaError.closed(message: CoreHolder.closedMessage)) {
            try await counting.value
        }
    }

    @Test func aCountInFlightWhenTheCopyClosesThrowsClosed() async throws {
        let gate = DispatchSemaphore(value: 0)
        let core = CountingCore(servedGate: gate)
        core.refuseCounts()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let counting = Task { try await copy.counts(of: ["a"], counted) }
        try await eventually("the count is asked of the server") { core.served.count == 1 }
        let closing = Task { await copy.close() }
        try await eventually("the copy is closing") {
            do {
                _ = try await copy.status()
                return false
            } catch Marfa.MarfaError.closed {
                return true
            }
        }
        gate.signal()
        await closing.value
        await #expect(throws: Marfa.MarfaError.closed(message: CoreHolder.closedMessage)) {
            try await counting.value
        }
    }

    @Test func aCountOfNoIdsChecksTheCopyFirst() async throws {
        let copy = WorkingCopy(holder: CoreHolder(CountingCore()), hasServer: false)
        // The witness: an open copy answers no ids with no counts.
        #expect(try await copy.counts(of: [], counted).isEmpty)
        await copy.close()
        await #expect(throws: Marfa.MarfaError.closed(message: CoreHolder.closedMessage)) {
            try await copy.counts(of: [], counted)
        }
    }

    @Test func aCanceledCountAsksForNoFurtherBatch() async throws {
        let gate = DispatchSemaphore(value: 0)
        let core = CountingCore(servedGate: gate)
        core.refuseCounts()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let ids = (0..<250).map { "item-\($0)" }
        let counting = Task { try await copy.counts(of: ids, counted) }
        try await eventually("the first batch is asked of the server") { core.served.count == 1 }
        counting.cancel()
        gate.signal()
        await #expect(throws: Marfa.MarfaError.self) { try await counting.value }
        #expect(core.served.count == 1)
        // The witness: uncanceled, every batch is asked.
        let open = Task { try await copy.counts(of: ids, counted) }
        for _ in 0..<3 { gate.signal() }
        #expect(try await open.value.count == 250 && core.served.count == 4)
        await copy.close()
    }

    @Test func noCountIsUnavailableOnlyWhereTheServerIsAbsentOrOutOfReach() async throws {
        for failure: MarfaCore.MarfaError in [
            .NoServer(message: "no server"), .Network(message: "offline"),
        ] {
            let core = CountingCore()
            core.refuseCounts()
            core.failServed(failure)
            let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
            await #expect(throws: CountError.unavailable(cause: Marfa.MarfaError(failure))) {
                try await copy.counts(of: ["a"], counted)
            }
            await copy.close()
        }
        // The copy's own count of rows, which needs the server, with none.
        let core = CountingCore()
        core.refuseCounts(.NoServer(message: "no server"))
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        await #expect(throws: CountError.self) { try await copy.counts(of: ["a"], .rows(table: "lines")) }
        await copy.close()
    }

    @Test func aServersRefusalOfACountIsTheRefusalItself() async throws {
        let refusals: [MarfaCore.MarfaError] = [
            .RateLimited(code: "rate_limited", message: "slow down", retryAfterSeconds: 5, server: nil),
            .Server(status: 503, code: "unavailable", message: "down", details: nil, server: nil),
            .Unauthorized(code: "unauthorized", message: "no", server: nil),
        ]
        for refusal in refusals {
            let core = CountingCore()
            core.refuseCounts()
            core.failServed(refusal)
            let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
            await #expect(throws: Marfa.MarfaError(refusal)) { try await copy.counts(of: ["a"], counted) }
            await copy.close()
        }
    }

    @Test func aServersCountsAreRefusedUnlessTheyAreTheAskedIdsOnceEachInOrderWithPossibleNumbers() async throws {
        let groups = #""status_groups":{"not_started":1,"in_progress":0,"completed":0,"canceled":0}"#
        let a = #"{"id":"a","total":1,\#(groups)}"#
        let b = #"{"id":"b","total":1,\#(groups)}"#
        let link = Marfa.Counted.backref(edgeType: "parent-of")
        let rows = Marfa.Counted.rows(table: "lines")
        let cases: [(String, Marfa.Counted, String)] = [
            ("missing", link, "[\(a)]"),
            ("reordered", link, "[\(b),\(a)]"),
            ("repeated", link, "[\(a),\(a)]"),
            ("extra", link, "[\(a),\(b),\(a)]"),
            ("a link without groups", link, #"[\#(a),{"id":"b","total":1}]"#),
            ("rows with groups", rows, #"[{"id":"a","total":1},\#(b)]"#),
            ("rows with null groups", rows, #"[{"id":"a","total":1},{"id":"b","total":1,"status_groups":null}]"#),
            ("a link with null groups", link, #"[\#(a),{"id":"b","total":1,"status_groups":null}]"#),
            ("a negative total", rows, #"[{"id":"a","total":-1},{"id":"b","total":1}]"#),
            ("a fractional total", rows, #"[{"id":"a","total":1.5},{"id":"b","total":1}]"#),
            (
                "a negative group", link,
                #"[\#(a),{"id":"b","total":1,"status_groups":{"not_started":2,"in_progress":-1,"completed":0,"canceled":0}}]"#
            ),
            (
                "groups above the total", link,
                #"[\#(a),{"id":"b","total":1,"status_groups":{"not_started":1,"in_progress":1,"completed":0,"canceled":0}}]"#
            ),
            (
                "groups that overflow", link,
                #"[\#(a),{"id":"b","total":9223372036854775807,"status_groups":{"not_started":9223372036854775807,"in_progress":9223372036854775807,"completed":0,"canceled":0}}]"#
            ),
        ]
        for (what, counted, answer) in cases {
            let server = try await serverAnswering(#"{"counts":\#(answer)}"#)
            defer { server.stop() }
            let client = try Server(url: server.url, key: "k")
            do {
                _ = try await client.itemCounts(of: ["a", "b", "a"], counted)
                Issue.record("\(what) was accepted")
            } catch {
                guard case .decoding = error else {
                    Issue.record("\(what) was refused \(error), not decoding")
                    continue
                }
            }
        }
        // The witness: whole answers of each kind are accepted.
        for (counted, answer) in [(link, "[\(a),\(b)]"), (rows, #"[{"id":"a","total":1},{"id":"b","total":2}]"#)] {
            let server = try await serverAnswering(#"{"counts":\#(answer)}"#)
            defer { server.stop() }
            let counts = try await Server(url: server.url, key: "k").itemCounts(of: ["a", "b", "a"], counted)
            #expect(counts.map(\.id) == ["a", "b"] && counts.allSatisfy { !$0.held })
        }
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
