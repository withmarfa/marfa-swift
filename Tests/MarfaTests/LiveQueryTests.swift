import Foundation
import MarfaCore
import Observation
import Synchronization
import Testing

@testable import Marfa

/// Reads a test counts, holds and fails on cue.
///
/// Each read answers `label` and its own number, such as `A2`, so a test sees
/// which read an answer came from.
final class Probe: Sendable {
    private struct State {
        var started = 0
        var finished: Set<Int> = []
        var held: Set<Int> = []
        var failing: Set<Int> = []
    }

    private let state = Mutex(State())

    var reads: Int { state.withLock { $0.started } }
    func finished(_ number: Int) -> Bool { state.withLock { $0.finished.contains(number) } }

    func hold(_ numbers: Int...) { state.withLock { $0.held.formUnion(numbers) } }
    func release(_ number: Int) { state.withLock { _ = $0.held.remove(number) } }
    func fail(_ numbers: Int...) { state.withLock { $0.failing.formUnion(numbers) } }

    func reading(_ label: String) -> Reading<String> {
        Reading(placeholder: "none") { _ in
            let number = self.state.withLock { state in
                state.started += 1
                return state.started
            }
            defer { self.state.withLock { _ = $0.finished.insert(number) } }
            while self.state.withLock({ $0.held.contains(number) }) {
                try await Task.sleep(for: .milliseconds(5))
            }
            if self.state.withLock({ $0.failing.contains(number) }) {
                throw Marfa.MarfaError.store(message: "boom")
            }
            return "\(label)\(number)"
        }
    }
}

private func told(_ origin: Marfa.Change.Origin) -> Marfa.Change {
    Marfa.Change(origin: origin, itemId: nil, edgeId: nil)
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct LiveQueries {
    static let entry = PropertyValues.entry

    static func fake() -> (FakeCore, WorkingCopy) {
        let core = FakeCore.writer()
        return (core, WorkingCopy(holder: CoreHolder(core), hasServer: true))
    }

    static func open(_ store: URL = temporaryStore(), server: Server? = nil) async throws -> WorkingCopy {
        let copy = try await WorkingCopy.open(store: store, server: server)
        try await copy.declareTypes([entry])
        return copy
    }

    static func make(_ copy: WorkingCopy, _ properties: JSONObject = [:]) async throws -> String {
        try #require(try await copy.items.create(Draft(type: "app.test.entry", properties: properties)).itemId)
    }

    static let entries = Reading<Rows<Marfa.Item>>.list(Marfa.ListFilters(type: "app.test.entry"))

    /// Once its first read has ended, so a change told next is one the query has a stream for.
    static func settled<Value>(_ query: LiveQuery<Value>) async throws {
        try await eventually("the first read ended") { !query.isLoading }
    }

    // MARK: The rows follow the copy

    @Test func aLocalWriteUpdatesTheRowsWithNoCallFromTheApp() async throws {
        let copy = try await Self.open()
        let query = LiveQuery(copy, reading: Self.entries)
        try await Self.settled(query)
        #expect(query.value.isEmpty && query.error == nil)

        let id = try await Self.make(copy, ["title": "first"])
        try await eventually("the created item shows") { query.value.map(\.id) == [id] }
        _ = try await copy.items.update(id, Edit(properties: ["title": "second"], baseVersion: 0))
        try await eventually("the edit shows") { query.value.first?.title == "second" }
        _ = try await copy.tags.add("favorite", to: id)
        try await eventually("the tag shows") { query.value.first?.tags == ["favorite"] }
        _ = try await copy.items.delete(id)
        try await eventually("the deleted item left") { query.value.isEmpty }
        #expect(query.error == nil)
        await copy.close()
    }

    @Test func aWriteMadeRightAfterTheQueryIsMadeIsNotMissed() async throws {
        let copy = try await Self.open()
        let query = LiveQuery(copy, reading: Self.entries)
        let id = try await Self.make(copy)
        try await eventually("the item made at once shows") { query.value.map(\.id) == [id] }
        await copy.close()
    }

    @Test(arguments: [false, true])
    func theRowsUpdateOfflineWithNoServerAndWithOneThatIsAway(hasServer: Bool) async throws {
        let server = hasServer ? Server(url: URL(string: "http://127.0.0.1:9")!, key: "k") : nil
        let copy = try await Self.open(server: server)
        let query = LiveQuery(copy, reading: Self.entries)
        try await Self.settled(query)
        let id = try await Self.make(copy, ["title": "offline"])
        try await eventually("the offline write shows") { query.value.map(\.id) == [id] }
        #expect(query.error == nil)
        try await bounded("close") { await copy.close() }
    }

    @Test func aBurstOfWritesEndsWithAllTheRows() async throws {
        let copy = try await Self.open()
        let query = LiveQuery(copy, reading: Self.entries)
        var made: Set<String> = []
        for number in 0..<30 { made.insert(try await Self.make(copy, ["title": .string("n\(number)")])) }
        try await eventually("every row shows") { Set(query.value.map(\.id)) == made }
        await copy.close()
    }

    nonisolated static let reloading: [Marfa.Change] = [
        told(.local(.addTag)),
        told(.server(event: "item.created", cursor: "1")),
        told(.answered(Marfa.DrainVerdict(id: "w", kind: .addTag, verdict: .accepted))),
        told(.saved(dataVersion: 3)),
        told(.queueDrained(Marfa.DrainReport())),
        told(.queueNotDrained(.network(message: "away"))),
        told(.refreshed(.hydrated)),
        told(.refreshed(.unfinished)),
        told(.refreshed(.caughtUp)),
        told(.refreshed(.drained)),
        told(.refreshed(.withdrawn)),
        told(.refreshed(.forgotten)),
        told(.refreshed(.pinned)),
        told(.refreshed(.unpinned)),
        told(.refreshed(.purged)),
        told(.refreshed(.folderWritten)),
        told(.refreshed(.viewWritten)),
        told(.refreshed(.catalog)),
    ]

    nonisolated static let silent: [Marfa.Change] = [
        told(.serverUnreachable(.network(message: "away"))),
        told(.serverReachable),
        told(.stopped(.unauthorized(code: "c", message: "m"))),
    ]

    @Test(arguments: reloading)
    func aChangeThatCanAlterARowMakesTheQueryReadAgain(change: Marfa.Change) async throws {
        let (_, copy) = Self.fake()
        let probe = Probe()
        let query = LiveQuery(copy, reading: probe.reading("A"))
        try await Self.settled(query)
        #expect(probe.reads == 1)
        copy.feed.announce(change)
        try await eventually("the change was read") { probe.reads == 2 && !query.isLoading }
        #expect(query.value == "A2")
        try await bounded("close") { await copy.close() }
    }

    @Test(arguments: silent)
    func aChangeThatAltersNoRowMakesNoRead(change: Marfa.Change) async throws {
        let (_, copy) = Self.fake()
        let probe = Probe()
        let query = LiveQuery(copy, reading: probe.reading("A"))
        try await Self.settled(query)
        copy.feed.announce(change)
        // Told in order, so the stream has passed the change when this one is read. Were
        // the change read, the sentinel would be read after it, as a third.
        copy.feed.announce(write(.addTag, item: "n1"))
        try await eventually("the sentinel was read") { probe.reads >= 2 && !query.isLoading }
        #expect(probe.reads == 2)
        try await bounded("close") { await copy.close() }
    }

    @Test func aHydrationAndACatchUpReadAgain() async throws {
        let (core, copy) = Self.fake()
        core.state.withLock {
            $0.caughtUp = MarfaCore.CatchUpReport(applied: 2, skipped: 0, cursor: "9", catalogChanged: false)
        }
        let probe = Probe()
        let query = LiveQuery(copy, reading: probe.reading("A"))
        try await Self.settled(query)
        _ = try await copy.hydrate(types: ["app.test.entry"], tier: .feed)
        try await eventually("the hydration was read") { probe.reads == 2 && !query.isLoading }
        _ = try await copy.catchUp()
        try await eventually("the catch-up was read") { probe.reads == 3 && !query.isLoading }
        try await bounded("close") { await copy.close() }
    }

    @Test func aServerEventThroughTheCoresWatchReadsAgain() async throws {
        let (core, copy) = Self.fake()
        let probe = Probe()
        let query = LiveQuery(copy, reading: probe.reading("A"))
        try await Self.settled(query)
        core.change(0, MarfaCore.Change.applied(event: "item.updated", itemId: "n1", edgeId: nil, cursor: "7"))
        try await eventually("the event was read") { probe.reads == 2 && !query.isLoading }
        try await bounded("close") { await copy.close() }
    }

    // MARK: Readings

    @Test func aSearchAnItemAndTheQueueAreReadings() async throws {
        let copy = try await Self.open()
        let id = try await Self.make(copy, ["title": "zebra crossing"])
        let search = LiveQuery(copy, reading: Reading<Rows<Marfa.Item>>.search("zebra"))
        let item = LiveQuery(copy, reading: Reading<Marfa.Item?>.item(id))
        let queue = LiveQuery(copy, reading: Reading<[Marfa.QueuedWrite]>.queue)
        try await eventually("all three read") {
            search.value.map(\.id) == [id] && item.value?.id == id && queue.value.count == 1
        }

        _ = try await copy.items.update(id, Edit(properties: ["title": "zebra herd"], baseVersion: 0))
        try await eventually("all three follow the edit") {
            search.value.first?.title == "zebra herd" && item.value?.title == "zebra herd" && queue.value.count == 2
        }
        _ = try await copy.items.delete(id)
        try await eventually("the item left the copy's view") { item.value == nil && search.value.isEmpty }
        await copy.close()
    }

    @Test func aListHonorsItsFiltersAndSort() async throws {
        let copy = try await Self.open()
        _ = try await Self.make(copy, ["title": "a"])
        let second = try await Self.make(copy, ["title": "b"])
        let limited = LiveQuery(copy, reading: .list(ListFilters(type: "app.test.entry", limit: 1)))
        let oldestFirst = LiveQuery(
            copy,
            reading: .list(ListFilters(type: "app.test.entry"), sort: Sort(field: .createdAt, direction: .ascending)))
        try await eventually("both read") { limited.value.count == 1 && oldestFirst.value.count == 2 }
        #expect(oldestFirst.value.last?.id == second)
        await copy.close()
    }

    // MARK: Filters change

    @Test func changingTheReadingReadsAgainAtOnce() async throws {
        let (_, copy) = Self.fake()
        let probe = Probe()
        let query = LiveQuery(copy, reading: probe.reading("A"))
        try await Self.settled(query)
        query.reading = probe.reading("B")
        try await eventually("the new reading was read") { query.value == "B2" && !query.isLoading }
        try await bounded("close") { await copy.close() }
    }

    @Test func aReadForTheOldFiltersThatEndsWhileTheNewOneRunsIsDropped() async throws {
        let (_, copy) = Self.fake()
        let probe = Probe()
        probe.hold(1, 2)
        let query = LiveQuery(copy, reading: probe.reading("A"))
        try await eventually("the first read began") { probe.reads == 1 }
        query.reading = probe.reading("B")
        try await eventually("the new filters read without waiting for the old read") { probe.reads == 2 }

        probe.release(1)
        try await eventually("the old read ended") { probe.finished(1) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(query.value == "none", "the old filters' rows were shown: \(query.value)")
        #expect(query.isLoading, "the old read's end was taken for the new one's")

        probe.release(2)
        try await eventually("the new read's rows show") { query.value == "B2" && !query.isLoading }
        try await bounded("close") { await copy.close() }
    }

    // MARK: Bursts

    @Test func aBurstWhileAReadRunsCausesOneMoreRead() {
        var schedule = ReadSchedule()
        let idle = schedule.heard()
        #expect(idle, "a change told to an idle query did not start a read")
        let first = schedule.start()
        var started = 0
        for _ in 0..<100 where schedule.heard() { started += 1 }
        #expect(started == 0, "\(started) changes started a read while one ran")
        let ended = schedule.end(first)
        #expect(ended == .again)
        let second = schedule.start()
        let last = schedule.end(second)
        #expect(last == .idle)
        #expect(!schedule.running)
        let after = schedule.heard()
        #expect(after)
    }

    @Test func aNewerReadMakesTheOlderObsolete() {
        var schedule = ReadSchedule()
        let first = schedule.start()
        let second = schedule.start()
        let older = schedule.end(first)
        #expect(older == .obsolete)
        #expect(schedule.running)
        let newer = schedule.end(second)
        #expect(newer == .idle)
        let again = schedule.end(second)
        #expect(again == .obsolete)
    }

    @Test func aBurstOfChangesStartsNoReadWhileOneRunsAndOneAfterIt() async throws {
        let (_, copy) = Self.fake()
        let probe = Probe()
        probe.hold(1)
        let query = LiveQuery(copy, reading: probe.reading("A"))
        try await eventually("the first read began") { probe.reads == 1 }
        for _ in 0..<100 { copy.feed.announce(write(.addTag, item: "n1")) }
        // The stream is in order and `.stopped` changes only `following`, so once it shows
        // the query has heard all 100 changes before it.
        copy.feed.announce(told(.stopped(.network(message: "sentinel"))))
        try await eventually("the query heard the burst") { query.following == .stopped(.network(message: "sentinel")) }
        #expect(probe.reads == 1, "\(probe.reads - 1) of 100 changes started a read while one ran")

        probe.release(1)
        try await eventually("the burst was read once more") { !query.isLoading && probe.reads == 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.reads == 2, "the burst caused \(probe.reads) reads")
        #expect(query.value == "A2")
        try await bounded("close") { await copy.close() }
    }

    @Test func refreshReturnsOnlyAfterAReadThatBeganAfterTheCall() async throws {
        let (_, copy) = Self.fake()
        let probe = Probe()
        let query = LiveQuery(copy, reading: probe.reading("A"))
        try await Self.settled(query)
        await query.refresh()
        #expect(probe.reads == 2 && query.value == "A2")

        probe.hold(3)
        copy.feed.announce(write(.addTag, item: "n1"))
        try await eventually("a read is in flight") { probe.reads == 3 }
        let done = Mutex(false)
        let refreshing = Task {
            await query.refresh()
            done.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(50))
        let returnedEarly = done.withLock { $0 }
        #expect(!returnedEarly, "refresh returned while an older read ran")
        probe.release(3)
        await refreshing.value
        #expect(probe.reads == 4 && query.value == "A4")
        try await bounded("close") { await copy.close() }
    }

    // MARK: Errors

    @Test func aFailedReadKeepsTheRowsAndTheNextChangeRecovers() async throws {
        let (_, copy) = Self.fake()
        let probe = Probe()
        probe.fail(2)
        let query = LiveQuery(copy, reading: probe.reading("A"))
        try await Self.settled(query)
        #expect(query.value == "A1")

        copy.feed.announce(write(.addTag, item: "n1"))
        try await eventually("the failure is shown") { query.error != nil && !query.isLoading }
        #expect(query.error as? Marfa.MarfaError == .store(message: "boom"))
        #expect(query.value == "A1", "a failed read emptied the rows")

        copy.feed.announce(write(.addTag, item: "n1"))
        try await eventually("the next change recovered") { query.error == nil && query.value == "A3" }
        try await bounded("close") { await copy.close() }
    }

    @Test func aDamagedRowIsListedWithItsFlagAndDoesNotFailTheQuery() async throws {
        let store = temporaryStore()
        let copy = try await PropertyValues.open(store)
        var ids: [String] = []
        for title in ["sound", "torn"] { ids.append(try await PropertyValues.create(copy, ["title": .string(title)])) }
        await copy.close()
        try PropertyValues.damage(store, "UPDATE items SET properties = '{\"title\":' WHERE id = '\(ids[1])'")

        let reopened = try await PropertyValues.open(store)
        let query = LiveQuery(reopened, reading: Self.entries)
        let torn = LiveQuery(reopened, reading: Reading<Marfa.Item?>.item(ids[1]))
        try await eventually("both read") { query.value.count == 2 && torn.value != nil }
        #expect(query.value.filter { $0.unreadableProperties != nil }.map(\.id) == [ids[1]])
        #expect(torn.value?.unreadableProperties != nil)
        #expect(query.error == nil && torn.error == nil)

        let added = try await PropertyValues.create(reopened, ["title": "later"])
        try await eventually("a write beside the damaged row shows") {
            Set(query.value.map(\.id)) == Set(ids + [added])
        }
        #expect(query.error == nil)
        await reopened.close()
    }

    // MARK: Following

    @Test func aWatchFailureLeavesTheStreamOpenAndTheRowsFollowLocalWrites() async throws {
        let (core, copy) = Self.fake()
        let probe = Probe()
        let query = LiveQuery(copy, reading: probe.reading("A"))
        try await Self.settled(query)
        #expect(query.following == .live)

        core.change(0, MarfaCore.Change.watchFailed(reason: .Network(message: "dropped"), cursor: "3"))
        try await eventually("the failure is shown") { query.following == .stopped(.network(message: "dropped")) }
        #expect(query.error == nil, "a follow failure is not a read failure")
        #expect(probe.reads == 1, "a stopped follow read")

        copy.feed.announce(write(.addTag, item: "n1"))
        try await eventually("a local write is still read") { probe.reads == 2 && !query.isLoading }
        #expect(query.following == .stopped(.network(message: "dropped")), "a read cleared the follow failure")

        core.change(0, MarfaCore.Change.applied(event: "item.updated", itemId: "n1", edgeId: nil, cursor: "8"))
        try await eventually("a server event shows the follow runs") { query.following == .live }
        try await bounded("close") { await copy.close() }
    }

    @Test func aHydrationAfterAWatchFailureShowsTheFollowRunsAgain() async throws {
        let (core, copy) = Self.fake()
        let probe = Probe()
        let query = LiveQuery(copy, reading: probe.reading("A"))
        try await Self.settled(query)
        core.change(0, MarfaCore.Change.watchFailed(reason: .Network(message: "dropped"), cursor: "3"))
        try await eventually("the failure is shown") { query.following == .stopped(.network(message: "dropped")) }
        _ = try await copy.hydrate(types: ["app.test.entry"], tier: .feed)
        try await eventually("the hydration shows the follow runs") { query.following == .live }
        try await bounded("close") { await copy.close() }
    }

    @Test func aHydrationThatFailsAfterAWatchFailureLeavesTheFailureShown() async throws {
        let (core, copy) = Self.fake()
        let probe = Probe()
        let query = LiveQuery(copy, reading: probe.reading("A"))
        try await Self.settled(query)
        core.change(0, MarfaCore.Change.watchFailed(reason: .Network(message: "dropped"), cursor: "3"))
        try await eventually("the failure is shown") { query.following == .stopped(.network(message: "dropped")) }
        let reads = probe.reads
        copy.feed.announce(told(.refreshed(.unfinished)))
        try await eventually("the unfinished fill was read") { probe.reads > reads && !query.isLoading }
        #expect(query.following == .stopped(.network(message: "dropped")), "a failed fill cleared the follow failure")
        try await bounded("close") { await copy.close() }
    }

    @Test func aCoreFaultEndsTheStreamAndNothingAsksAgainUntilRefresh() async throws {
        let (core, copy) = Self.fake()
        let probe = Probe()
        let query = LiveQuery(copy, reading: probe.reading("A"))
        try await Self.settled(query)

        core.fail(0, with: .Store(message: "fault"))
        try await eventually("the end is shown") { query.following == .ended(.store(message: "fault")) }
        #expect(core.places.count == 1, "the query asked for a new place by itself")
        copy.feed.announce(write(.addTag, item: "n1"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.reads == 1, "an ended query read")

        await query.refresh()
        #expect(core.places.count == 2, "refresh did not ask for a new stream")
        #expect(query.following == .live)
        copy.feed.announce(write(.addTag, item: "n1"))
        try await eventually("the new stream is heard") { probe.reads >= 3 && !query.isLoading }
        try await bounded("close") { await copy.close() }
    }

    @Test func aCopyClosedAfterAWatchFailureEndsTheQueryWithNoError() async throws {
        let (core, copy) = Self.fake()
        let probe = Probe()
        let query = LiveQuery(copy, reading: probe.reading("A"))
        try await Self.settled(query)
        core.change(0, MarfaCore.Change.watchFailed(reason: .Network(message: "dropped"), cursor: "3"))
        try await eventually("the failure is shown") { query.following == .stopped(.network(message: "dropped")) }

        try await bounded("close") { await copy.close() }
        try await eventually("the end is shown") { query.following == .ended(nil) }
        // Left alone, the end stays what the close made it.
        try await Task.sleep(for: .milliseconds(100))
        #expect(query.following == .ended(nil), "a close after a failure was shown as the failure: \(query.following)")
    }

    @Test func aCopyClosedWhileTheQueryLivesEndsItKeepingItsRows() async throws {
        let copy = try await Self.open()
        let id = try await Self.make(copy)
        let query = LiveQuery(copy, reading: Self.entries)
        try await eventually("the row shows") { query.value.map(\.id) == [id] }

        await copy.close()
        try await eventually("the end is shown") { query.following == .ended(nil) }
        #expect(query.value.map(\.id) == [id], "closing emptied the rows")

        await query.refresh()
        if case .closed? = query.error as? Marfa.MarfaError {
        } else {
            Issue.record("error: \(String(describing: query.error))")
        }
        #expect(query.following == .ended(nil))
        #expect(query.value.map(\.id) == [id])
    }

    // MARK: Releasing

    @Test func releasingTheQueryEndsItsStreamAndItsPlaceInTheWatch() async throws {
        let (core, copy) = Self.fake()
        let probe = Probe()
        var query: LiveQuery<String>? = LiveQuery(copy, reading: probe.reading("A"))
        weak let released = query
        try await Self.settled(try #require(query))
        #expect(copy.feed.count == 1)
        #expect(!core.places[0].stopped)

        query = nil
        try await eventually("the query was released") { released == nil }
        try await eventually("the stream ended") { copy.feed.count == 0 }
        try await eventually("the place in the watch stopped") { core.places[0].stopped }
        try await bounded("close") { await copy.close() }
    }

    @Test func releasingTheQueryWhileItReadsDropsTheReadAndHoldsNothing() async throws {
        let (_, copy) = Self.fake()
        let probe = Probe()
        probe.hold(1)
        var query: LiveQuery<String>? = LiveQuery(copy, reading: probe.reading("A"))
        weak let released = query
        try await eventually("the read began") { probe.reads == 1 }

        query = nil
        try await eventually("a read in flight did not keep the query") { released == nil }
        try await eventually("the stream ended") { copy.feed.count == 0 }
        probe.release(1)
        try await bounded("close") { await copy.close() }
    }

    @Test func aRealCopyIsLetGoOfWhenItsQueryIs() async throws {
        let copy = try await Self.open()
        var query: LiveQuery<Rows<Marfa.Item>>? = LiveQuery(copy, reading: Self.entries)
        try await Self.settled(try #require(query))
        #expect(copy.feed.count == 1)
        query = nil
        try await eventually("the stream ended") { copy.feed.count == 0 }
        await copy.close()
    }

    // MARK: Observation

    @Test func aViewObservingTheValueIsToldWhenItChanges() async throws {
        let copy = try await Self.open()
        let query = LiveQuery(copy, reading: Self.entries)
        try await Self.settled(query)
        var seen = Observations { query.value.count }.makeAsyncIterator()
        #expect(await seen.next() == 0)
        _ = try await Self.make(copy)
        #expect(await seen.next() == 1)
        await copy.close()
    }

    @Test func aReadThatChangesNothingTellsNoObserver() async throws {
        let (_, copy) = Self.fake()
        let constant = Reading<String>(placeholder: "none") { _ in "same" }
        let query = LiveQuery(copy, reading: constant)
        try await eventually("the first read ended") { !query.isLoading && query.value == "same" }
        let notified = Mutex(0)
        withObservationTracking {
            _ = query.value
        } onChange: {
            notified.withLock { $0 += 1 }
        }
        await query.refresh()
        await query.refresh()
        let equalReads = notified.withLock { $0 }
        #expect(equalReads == 0, "an equal read told an observer")

        // The witness: a different answer does.
        query.reading = Reading(placeholder: "none") { _ in "other" }
        try await eventually("a different answer was read") { query.value == "other" }
        let differentReads = notified.withLock { $0 }
        #expect(differentReads == 1)
        try await bounded("close") { await copy.close() }
    }
}
