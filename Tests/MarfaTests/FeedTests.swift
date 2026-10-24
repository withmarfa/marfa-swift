import Foundation
import MarfaCore
import Testing

@testable import Marfa

private func stopped(_ error: Marfa.MarfaError) -> Marfa.Change {
    Marfa.Change(origin: .stopped(error), itemId: nil, edgeId: nil)
}

private func refreshed(_ refresh: Marfa.Change.Refresh) -> Marfa.Change {
    Marfa.Change(origin: .refreshed(refresh), itemId: nil, edgeId: nil)
}

@Suite(.timeLimit(.minutes(1)))
struct Changes {
    @Test(arguments: Errors.cases)
    func aWatchThatFailedIsToldToTheStreamAsItsTypedFailure(
        coreError: MarfaCore.MarfaError, expected: Marfa.MarfaError
    ) async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let heard = Heard(copy.changes())
        core.change(0, MarfaCore.Change.watchFailed(reason: coreError, cursor: "3"))
        try await eventually("the stream receives the typed failure") { heard.all == [stopped(expected)] }
        try await bounded("close") { await copy.close() }
    }

    @Test func aWriteIsToldToEveryStreamHeldAndNoneAfterItIsLetGo() async throws {
        let feed = Feed(holder: CoreHolder(FakeCore.writer()), watched: false)
        let (first, firstContinuation) = AsyncStream<Marfa.Change>.makeStream()
        let (second, secondContinuation) = AsyncStream<Marfa.Change>.makeStream()
        let firstToken = try #require(feed.add(firstContinuation))
        _ = try #require(feed.add(secondContinuation))
        var firstHeard = first.makeAsyncIterator()
        var secondHeard = second.makeAsyncIterator()

        feed.announce(write(.addTag, item: "n1"))
        #expect(await firstHeard.next() == Marfa.Change(origin: .local(.addTag), itemId: "n1", edgeId: nil))
        #expect(await secondHeard.next() == Marfa.Change(origin: .local(.addTag), itemId: "n1", edgeId: nil))

        feed.remove(firstToken)
        feed.announce(write(.removeTag, item: "n2"))
        // Finished only after the write was told, so a write that reached the
        // stream would come out of it before the end.
        firstContinuation.finish()
        #expect(await firstHeard.next() == nil, "a stream let go was still told")
        #expect(await secondHeard.next() == Marfa.Change(origin: .local(.removeTag), itemId: "n2", edgeId: nil))
    }

    @Test func aLocalChangeNamesTheWritesEdgeNotItsTarget() async throws {
        let feed = Feed(holder: CoreHolder(FakeCore.writer()), watched: false)
        let (stream, continuation) = AsyncStream<Marfa.Change>.makeStream()
        _ = try #require(feed.add(continuation))
        var heard = stream.makeAsyncIterator()
        feed.announce(write(.createEdge, item: "a", target: "b", edge: "e1"))
        #expect(await heard.next() == Marfa.Change(origin: .local(.createEdge), itemId: "a", edgeId: "e1"))
    }

    @Test func endingTheIterationLetsGoOfTheStream() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let stream = copy.changes()
        #expect(copy.feed.count == 1)
        let listening = Task {
            for await _ in stream {}
        }
        listening.cancel()
        await listening.value
        try await eventually("the stream was let go") { copy.feed.count == 0 }
    }

    @Test func closingEndsEveryStreamAndRefusesNew() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        var held = copy.changes().makeAsyncIterator()
        #expect(copy.feed.count == 1)
        try await bounded("close") { await copy.close() }
        #expect(await held.next() == nil)
        var later = copy.changes().makeAsyncIterator()
        #expect(await later.next() == nil)
        #expect(copy.feed.count == 0)
    }

    /// The real core makes a follow on a store with no hydration wait for
    /// one, asking the server nothing, so the streams hear no failure.
    @Test func aFollowBeforeTheFirstHydrationWaitsRatherThanFailing() async throws {
        let copy = try await WorkingCopy.open(
            store: temporaryStore(), server: Server(url: URL(string: "http://127.0.0.1:9")!, key: "k"))
        let heard = Heard(copy.changes())
        try await Task.sleep(for: .milliseconds(300))
        #expect(heard.all.isEmpty, "\(heard.all)")
        let later = Heard(copy.changes())
        try await Task.sleep(for: .milliseconds(100))
        #expect(later.all.isEmpty, "a stream taken while the follow waited was told \(later.all)")
        copy.feed.announce(write(.addTag, item: "n1"))
        try await eventually("a local write was told to both") { heard.locals.count == 1 && later.locals.count == 1 }
        #expect(heard.stops.isEmpty && later.stops.isEmpty)
        try await bounded("close") { await copy.close() }
    }

    @Test func eachStreamTakesItsOwnPlaceInTheWatch() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let first = Heard(copy.changes())
        let second = Heard(copy.changes())
        #expect(core.places.count == 2)
        core.change(0, MarfaCore.Change.applied(event: "item.created", itemId: "n1", edgeId: nil, cursor: "7"))
        core.change(1, MarfaCore.Change.applied(event: "item.created", itemId: "n2", edgeId: nil, cursor: "8"))
        try await eventually("each stream was told what its own place heard") {
            first.all.map(\.itemId) == ["n1"] && second.all.map(\.itemId) == ["n2"]
        }
        try await bounded("close") { await copy.close() }
    }

    @Test func aServerChangeCarriesItsCursorAndEdge() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let heard = Heard(copy.changes())
        core.change(0, MarfaCore.Change.applied(event: "edge.created", itemId: "a", edgeId: "e1", cursor: "42"))
        let told = Marfa.Change(origin: .server(event: "edge.created", cursor: "42"), itemId: "a", edgeId: "e1")
        try await eventually("the change was told") { heard.all == [told] }
        try await bounded("close") { await copy.close() }
    }

    @Test func aStreamThatReadAChangedCatalogIsToldAsACatalogRefresh() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let heard = Heard(copy.changes())
        core.change(0, MarfaCore.Change.catalogChanged(cursor: "9"))
        core.change(0, MarfaCore.Change.applied(event: "item.created", itemId: "n1", edgeId: nil, cursor: "10"))
        let item = Marfa.Change(origin: .server(event: "item.created", cursor: "10"), itemId: "n1", edgeId: nil)
        try await eventually("both changes were told") { heard.all.count == 2 }
        #expect(heard.all == [refreshed(.catalog), item])
        try await bounded("close") { await copy.close() }
    }

    @Test func aStreamLetGoStopsItsPlaceAndNoOtherStream() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let first = Heard(copy.changes())
        let second = Heard(copy.changes())
        first.stop()
        try await eventually("the first place was stopped") { core.places[0].stopped }
        #expect(!core.places[1].stopped)
        core.change(1, MarfaCore.Change.applied(event: "item.created", itemId: "n1", edgeId: nil, cursor: "7"))
        try await eventually("the second stream was told") { second.all.count == 1 }
        second.stop()
        try await eventually("the second place was stopped") { core.places[1].stopped }
        try await bounded("close") { await copy.close() }
    }

    /// What the place a key change replaced says late is not the stream's.
    @Test func whatAPlaceLetGoSaysLateIsIgnored() async throws {
        let core = FakeCore.writer()
        let feed = Feed(holder: CoreHolder(core), watched: true)
        let (stream, continuation) = AsyncStream<Marfa.Change>.makeStream()
        _ = try #require(feed.add(continuation))
        let heard = Heard(stream)
        try await bounded("suspend") { try await feed.suspend() }
        feed.resume(readsOnly: false)
        try #require(core.places.count == 2)

        core.endAgain(0, with: .Network(message: "late"))
        core.change(0, MarfaCore.Change.applied(event: "item.created", itemId: "late", edgeId: nil, cursor: "1"))
        core.change(1, MarfaCore.Change.applied(event: "item.created", itemId: "current", edgeId: nil, cursor: "2"))
        try await eventually("the current place's change was told") { !heard.all.isEmpty }
        #expect(heard.all.map(\.itemId) == ["current"])
        #expect(heard.stops.isEmpty)
        try await bounded("close") { await feed.close() }
    }

    /// The new place is given what the stream was last told, so the core tells the
    /// stream the server is back, and tells a stream it never told nothing.
    @Test func aNewPlaceIsGivenWhatTheStreamWasLastToldOfTheServer() async throws {
        let core = FakeCore.writer()
        let feed = Feed(holder: CoreHolder(core), watched: true)
        let (told, toldContinuation) = AsyncStream<Marfa.Change>.makeStream()
        let (other, otherContinuation) = AsyncStream<Marfa.Change>.makeStream()
        _ = try #require(feed.add(toldContinuation))
        _ = try #require(feed.add(otherContinuation))
        let heard = Heard(told)
        withExtendedLifetime(other) {}
        core.change(
            0, MarfaCore.Change.serverUnreachable(reason: .Network(message: "gone"), cursor: "3"))
        try await eventually("the first stream was told the server went") { heard.all.count == 1 }

        try await bounded("suspend") { try await feed.suspend() }
        feed.resume(readsOnly: false)
        try #require(core.places.count == 4)
        // The feed resumes its streams in no set order.
        let given = core.places.indices.dropFirst(2).filter { core.places[$0].toldUnreachable }
        #expect(given.count == 1, "only the stream told the server was gone should be given a place told so")
        let place = try #require(given.first)
        core.change(place, MarfaCore.Change.serverReachable(cursor: "3"))
        try await eventually("the stream was told the server is back") { heard.all.count == 2 }
        try await bounded("suspend") { try await feed.suspend() }
        feed.resume(readsOnly: false)
        let again = core.places.dropFirst(4).filter(\.toldUnreachable).count
        #expect(again == 0, "a stream told the server was back was given a place told it was gone")
        try await bounded("close") { await feed.close() }
    }

    @Test func anEndWithAnErrorFromAPlaceAlreadyLetGoIsNotTold() async throws {
        let core = FakeCore.writer()
        let feed = Feed(holder: CoreHolder(core), watched: true)
        let (stream, continuation) = AsyncStream<Marfa.Change>.makeStream()
        _ = try #require(feed.add(continuation))
        let heard = Heard(stream)
        try await bounded("suspend") { try await feed.suspend() }
        core.endAgain(0, with: .Network(message: "as it stopped"))
        feed.resume(readsOnly: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(heard.stops.isEmpty, "a place already left told its error")
        try await bounded("close") { await feed.close() }
    }

    /// A fault in the core is told to its stream, which then ends and is not revived.
    @Test func aFaultInTheCoreEndsTheStreamAfterTellingTheError() async throws {
        let core = FakeCore.writer()
        let next = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core, reopen: { _ in next }), hasServer: true)
        var heard = copy.changes().makeAsyncIterator()
        let fault = MarfaCore.MarfaError.Invalid(message: "the watch stopped on a fault in the core")
        core.fail(0, with: fault)
        #expect(await heard.next() == stopped(.invalid(message: "the watch stopped on a fault in the core")))
        #expect(await heard.next() == nil, "the stream stayed open after the fault")
        #expect(copy.feed.count == 0)

        core.change(0, MarfaCore.Change.applied(event: "item.created", itemId: "late", edgeId: nil, cursor: "1"))
        copy.feed.announce(write(.addTag, item: "n1"))
        _ = try await bounded("the catch-up") { try await copy.catchUp() }
        try await bounded("useKey") { try await copy.useKey("new-key") }
        #expect(core.places.count == 1, "a recovery took a new place for a stream the fault ended")
        #expect(next.places.isEmpty, "a key change revived a stream the fault ended")
        try await bounded("close") { await copy.close() }
    }

    @Test func aHydrationAndACatchUpLeaveEveryPlaceInTheWatchAlone() async throws {
        for core in [FakeCore.writer(), FakeCore.reader()] {
            let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
            let heard = Heard(copy.changes())
            _ = try await bounded("the hydration") { try await copy.hydrate(types: ["core.note"], tier: .feed) }
            core.state.withLock { $0.caughtUp.applied = 2 }
            _ = try await bounded("the catch-up") { try await copy.catchUp() }
            try await eventually("the hydration and the catch-up that applied events were told") {
                heard.all == [refreshed(.hydrated), refreshed(.caughtUp)]
            }
            #expect(core.places.count == 1)
            let stopped = core.places.map(\.stopped)
            #expect(stopped == [false], "a place was stopped for a recovery")
            try await bounded("close") { await copy.close() }
        }
    }

    /// A catch-up reads the catalog before it applies anything, and may
    /// change it while applying no event.
    @Test func aCatchUpThatChangedTheCatalogIsToldSo() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let heard = Heard(copy.changes())
        _ = try await bounded("the catch-up") { try await copy.catchUp() }
        core.state.withLock { $0.catchUpChangesCatalog = true }
        _ = try await bounded("the catch-up") { try await copy.catchUp() }
        core.state.withLock { $0.caughtUp.applied = 1 }
        _ = try await bounded("the catch-up") { try await copy.catchUp() }
        try await eventually("each catch-up that changed the catalog was told") { heard.all.count == 3 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(heard.all == [refreshed(.catalog), refreshed(.catalog), refreshed(.caughtUp)])
        try await bounded("close") { await copy.close() }
    }

    /// The catalog is read and kept before a catch-up applies anything.
    @Test func aCatchUpThatChangedTheCatalogAndThenFailedIsToldBoth() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let heard = Heard(copy.changes())
        core.state.withLock {
            $0.catchUpChangesCatalog = true
            $0.catchUpFails = .CopyExpired(reason: "aged_out", message: "m")
        }
        await #expect(throws: Marfa.MarfaError.copyExpired(reason: "aged_out", message: "m")) {
            _ = try await bounded("the catch-up") { try await copy.catchUp() }
        }
        try await eventually("the catalog change was told") { !heard.all.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(heard.all == [refreshed(.catalog)], "the catalog change was not told exactly once: \(heard.all)")
        try await bounded("close") { await copy.close() }
    }

    /// The witness for the test above: the same failure with the catalog
    /// untouched tells nothing.
    @Test func aCatchUpThatFailedWithTheCatalogUntouchedTellsNothing() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let heard = Heard(copy.changes())
        core.state.withLock { $0.catchUpFails = .CopyExpired(reason: "aged_out", message: "m") }
        await #expect(throws: Marfa.MarfaError.copyExpired(reason: "aged_out", message: "m")) {
            _ = try await bounded("the catch-up") { try await copy.catchUp() }
        }
        core.state.withLock { $0.catchUpChangesCatalog = true }
        _ = try? await bounded("the catch-up") { try await copy.catchUp() }
        try await eventually("the catalog change was told") { !heard.all.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(heard.all == [refreshed(.catalog)], "the catalog change was not told exactly once: \(heard.all)")
        try await bounded("close") { await copy.close() }
    }

    /// The core told the failure typed, and the translated error and the
    /// cancellation mapping hold on the error inside it.
    @Test(arguments: Errors.cases)
    func aFailedCatchUpThrowsTheErrorInsideItsFailure(coreError: MarfaCore.MarfaError, expected: Marfa.MarfaError)
        async throws
    {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        core.state.withLock {
            $0.catchUpChangesCatalog = true
            $0.catchUpFails = coreError
        }
        await #expect(throws: expected) {
            _ = try await bounded("the catch-up") { try await copy.catchUp() }
        }
        try await bounded("close") { await copy.close() }
    }

    @Test func aDrainThatRecordedVerdictsIsToldAndTakesNoNewPlaceInTheWatch() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let heard = Heard(copy.changes())
        core.change(0, MarfaCore.Change.watchFailed(reason: .Network(message: "gone"), cursor: "3"))
        _ = try await copy.queue.drain()
        let refusal = MarfaCore.Refusal(
            reason: "validation_error", code: "validation_error", message: "m",
            fields: [MarfaCore.FieldRefusal(field: "title", message: "too long")], trashed: false, grant: nil)
        core.state.withLock {
            $0.drained.verdicts = [
                MarfaCore.DrainVerdict(
                    id: "q", kind: .createItem, itemId: "n1", edgeId: nil, verdict: .accepted, refusals: 0,
                    replayed: false),
                MarfaCore.DrainVerdict(
                    id: "r", kind: .createEdge, itemId: "n1", edgeId: "e1", verdict: .refused(refusal: refusal),
                    refusals: 1, replayed: false),
                MarfaCore.DrainVerdict(
                    id: "w", kind: .updateItem, itemId: "n2", edgeId: nil, verdict: nil, refusals: 0,
                    replayed: false),
            ]
        }
        let report = try await copy.queue.drain()
        let answered = report.verdicts.prefix(2).map {
            Marfa.Change(origin: .answered($0), itemId: $0.itemId, edgeId: $0.edgeId)
        }
        try await eventually("the drain that recorded a verdict was told") { heard.all.count == 4 }
        #expect(heard.all == [stopped(.network(message: "gone"))] + answered + [refreshed(.drained)])
        guard case .answered(let edge) = heard.all[2].origin, case .refused(let refused) = edge.verdict else {
            Issue.record("the refused edge write was not told with its refusal: \(heard.all)")
            return
        }
        #expect(refused.fields == [Marfa.FieldRefusal(field: "title", message: "too long")])
        #expect(heard.all[2].edgeId == "e1")
        #expect(core.places.count == 1, "a drain took a new place in the watch")
        try await bounded("close") { await copy.close() }
    }

    @Test func theWatchsOwnDrainIsToldWithItsAnswersAndItsReport() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let heard = Heard(copy.changes())
        let verdict = MarfaCore.DrainVerdict(
            id: "q", kind: .createItem, itemId: "n1", edgeId: nil, verdict: .accepted, refusals: 0, replayed: false)
        let report = MarfaCore.DrainReport(
            answered: 1, held: 0, undelivered: 0, unsent: 0, unmade: 0, unavailable: nil, verdicts: [verdict],
            stopped: nil, unclaimedSources: [], retryAfterSeconds: nil)
        core.change(0, MarfaCore.Change.queueDrained(report: report, cursor: "3"))
        let told = Marfa.DrainReport(report)
        try await eventually("the drain was told") { heard.all.count == 3 }
        #expect(
            heard.all == [
                Marfa.Change(origin: .answered(told.verdicts[0]), itemId: "n1", edgeId: nil),
                refreshed(.drained),
                Marfa.Change(origin: .queueDrained(told), itemId: nil, edgeId: nil),
            ])
        // The witness: a drain that answered nothing tells only its report.
        let idle = MarfaCore.DrainReport(
            answered: 0, held: 0, undelivered: 0, unsent: 0, unmade: 0, unavailable: nil, verdicts: [], stopped: nil,
            unclaimedSources: [], retryAfterSeconds: nil)
        core.change(0, MarfaCore.Change.queueDrained(report: idle, cursor: "3"))
        try await eventually("the idle drain was told") { heard.all.count == 4 }
        #expect(heard.all[3] == Marfa.Change(origin: .queueDrained(Marfa.DrainReport(idle)), itemId: nil, edgeId: nil))
        try await bounded("close") { await copy.close() }
    }

    @Test func aWatchDrainThatStoppedIsToldWithItsError() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let heard = Heard(copy.changes())
        core.change(
            0,
            MarfaCore.Change.queueNotDrained(
                error: .RateLimited(code: "rate_limited", message: "slow", retryAfterSeconds: 4), cursor: "3"))
        try await eventually("the stop was told") { heard.all.count == 1 }
        #expect(
            heard.all == [
                Marfa.Change(
                    origin: .queueNotDrained(.rateLimited(code: "rate_limited", message: "slow", retryAfterSeconds: 4)),
                    itemId: nil, edgeId: nil)
            ])
        #expect(!core.places[0].ended, "a drain that stopped ended the place in the watch")
        try await bounded("close") { await copy.close() }
    }

    @Test func aWithdrawThatTookAWriteIsToldOnce() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let heard = Heard(copy.changes())
        core.state.withLock { $0.withdrawable = ["q"] }
        #expect(try await copy.queue.withdraw("other") == false)
        #expect(try await copy.queue.withdraw("q"))
        #expect(try await copy.queue.withdraw("q") == false)
        try await eventually("the withdraw was told") { heard.all == [refreshed(.withdrawn)] }
        try await Task.sleep(for: .milliseconds(200))
        #expect(heard.all == [refreshed(.withdrawn)])
        try await bounded("close") { await copy.close() }
    }

    @Test func clearingWritesFromTheQueueIsToldOnceForEachCallThatCleared() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let heard = Heard(copy.changes())
        core.state.withLock {
            $0.answered = ["a", "b", "c"]
            $0.refused = ["r"]
        }
        #expect(try await copy.queue.forgetAnswered(ids: ["a", "absent"]) == 1)
        #expect(try await copy.queue.forgetAnswered() == 2)
        #expect(try await copy.queue.discard("r"))
        // The same calls with nothing left to clear.
        #expect(try await copy.queue.forgetAnswered(ids: ["a"]) == 0)
        #expect(try await copy.queue.forgetAnswered() == 0)
        #expect(try await copy.queue.discard("r") == false)
        try await eventually("the clearing was told") { heard.all.count >= 3 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(heard.all == [refreshed(.forgotten), refreshed(.forgotten), refreshed(.forgotten)])
        try await bounded("close") { await copy.close() }
    }

    @Test func closingReturnsOnceEveryPlaceInTheWatchHasEnded() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let first = Heard(copy.changes())
        let second = Heard(copy.changes())
        #expect(core.places.count == 2)
        try await bounded("close") { await copy.close() }
        let ended = core.places.map(\.ended)
        #expect(ended == [true, true], "close returned while a place in the watch still held the store")
        withExtendedLifetime((first, second)) {}
    }

    /// This fake keeps every listener for good, so a listener holding its
    /// feed strongly would keep the core, and the store, past the copy.
    @Test func aClosedCopyLetGoIsNotHeldByItsListeners() async throws {
        let core = FakeCore.writer()
        weak var held: Feed?
        try await { () async throws in
            let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
            held = copy.feed
            let heard = Heard(copy.changes())
            #expect(core.places.count == 1)
            try await bounded("close") { await copy.close() }
            withExtendedLifetime(heard) {}
        }()
        #expect(core.places[0].ended)
        try await eventually("the feed was let go") { held == nil }
    }

    @Test func aStreamRefusedAPlaceInTheWatchIsToldWhyAndEnds() async throws {
        let core = FakeCore.reader()
        let next = FakeCore.reader()
        core.state.withLock { $0.watchRefused = .Invalid(message: "gone") }
        let copy = WorkingCopy(holder: CoreHolder(core, reopen: { _ in next }), hasServer: true)
        var heard = copy.changes().makeAsyncIterator()
        #expect(await heard.next() == stopped(.invalid(message: "gone")))
        #expect(await heard.next() == nil, "the stream stayed open after it was refused")
        #expect(copy.feed.count == 0)
        try await bounded("useKey") { try await copy.useKey("new-key") }
        #expect(next.places.isEmpty, "a key change revived a stream that was refused")
        try await bounded("close") { await copy.close() }
    }

    /// The core reads a reader's baseline as the place is taken, which can wait
    /// on the store.
    @Test func aStreamJoiningWhileTheStoreIsBusyHoldsNothingElse() async throws {
        let core = FakeCore.reader()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let gate = core.holdNextWatch()
        let listening = Task.detached { Heard(copy.changes()) }
        try await eventually("the watch call is held") { core.aWatchWasHeld }
        _ = try await bounded("the feed's count", within: 1) { copy.feed.count }
        copy.feed.announce(write(.addTag, item: "n1"))
        gate.signal()
        let heard = try await bounded("changes()") { await listening.value }
        try await eventually("the place was taken") { core.places.count == 1 }
        core.change(0, MarfaCore.Change.saved(dataVersion: 1, cursor: ""))
        try await eventually("the save was told") { heard.saves.count == 1 }
        try await bounded("close") { await copy.close() }
    }
}

/// A follow the core stopped because the server's event log let the copy's cursor go.
@Suite(.timeLimit(.minutes(1)))
struct ARefill {
    static let pace = Feed.RefillPace(first: .milliseconds(100), most: .milliseconds(400), settle: .seconds(5))
    static let agedOut = MarfaCore.MarfaError.CopyExpired(
        reason: "the event log no longer holds the cursor 3 (oldest retained id 9)", message: "rebuild the copy")

    static func stale() -> FakeCore {
        let core = FakeCore.writer()
        core.state.withLock {
            $0.hydration = .stale
            $0.slice = (["core.note"], .library, ["core.link"])
        }
        return core
    }

    static func copy(_ core: FakeCore) -> WorkingCopy {
        WorkingCopy(holder: CoreHolder(core), hasServer: true, refillPace: pace)
    }

    static func gaps(_ core: FakeCore) -> [Duration] {
        let began = core.state.withLock { $0.hydrations }
        return zip(began, began.dropFirst()).map { $0.duration(to: $1) }
    }

    @Test func aStaleCopyIsFilledAgainOverItsSliceAndItsStreamsAreNotStopped() async throws {
        let core = Self.stale()
        let copy = Self.copy(core)
        let heard = Heard(copy.changes())
        core.change(0, .watchFailed(reason: Self.agedOut, cursor: "3"))
        try await eventually("the refill was told") { heard.all == [refreshed(.hydrated)] }
        let options = try #require(core.state.withLock { $0.hydrationOptions })
        #expect(options.types == ["core.note"] && options.tier == .library && options.edgeTypes == ["core.link"])
        try await Task.sleep(for: .milliseconds(300))
        #expect(heard.all == [refreshed(.hydrated)])
        #expect(core.state.withLock { $0.hydrations.count } == 1)
        await copy.close()
    }

    @Test func aRefillTheNetworkKeepsFailingIsTriedFurtherApartEachTime() async throws {
        let core = Self.stale()
        core.state.withLock {
            $0.hydrateFails = .Network(message: "offline")
            $0.hydrateFailsFirst = 4
        }
        let copy = Self.copy(core)
        let heard = Heard(copy.changes())
        core.change(0, .watchFailed(reason: Self.agedOut, cursor: "3"))
        try await eventually("the refill was made in the end", within: 10) {
            heard.all.last == refreshed(.hydrated)
        }
        let gaps = Self.gaps(core)
        #expect(gaps.count == 4)
        for (gap, least) in zip(gaps, [100, 200, 400, 400]) {
            #expect(gap >= .milliseconds(least), "\(gaps)")
        }
        #expect(gaps.last.map { $0 < .milliseconds(800) } == true, "the wait grew past its most: \(gaps)")
        #expect(heard.stops.isEmpty)
        #expect(heard.all.filter { $0 == refreshed(.unfinished) }.count == 4)
        await copy.close()
    }

    @Test func aFollowThatStopsAgainSoonAfterARefillWaitsBeforeTheNext() async throws {
        let core = Self.stale()
        let copy = Self.copy(core)
        let heard = Heard(copy.changes())
        core.change(0, .watchFailed(reason: Self.agedOut, cursor: "3"))
        try await eventually("the first refill was told") { heard.all.count == 1 }
        core.change(0, .watchFailed(reason: Self.agedOut, cursor: "3"))
        try await eventually("the second refill was told") { heard.all.count == 2 }
        core.change(0, .watchFailed(reason: Self.agedOut, cursor: "3"))
        try await eventually("the third refill was told") { heard.all.count == 3 }
        let gaps = Self.gaps(core)
        #expect(gaps.count == 2)
        #expect(gaps.first.map { $0 >= .milliseconds(100) } == true, "\(gaps)")
        #expect(gaps.last.map { $0 >= .milliseconds(200) } == true, "\(gaps)")
        #expect(heard.stops.isEmpty)
        await copy.close()
    }

    static let needThePerson: [(MarfaCore.Hydration, MarfaCore.MarfaError?, Marfa.MarfaError)] = [
        // Another instance answers at the address: the copy must be replaced.
        (
            .expired, nil,
            .copyExpired(
                reason: "the event log no longer holds the cursor 3 (oldest retained id 9)",
                message: "rebuild the copy")
        ),
        // The refill itself is refused: signed out, or a different instance.
        (.stale, .Unauthorized(code: "invalid_key", message: "no"), .unauthorized(code: "invalid_key", message: "no")),
        (
            .stale, .CopyExpired(reason: "instance_changed", message: "m"),
            .copyExpired(reason: "instance_changed", message: "m")
        ),
    ]

    @Test(arguments: needThePerson)
    func aStopNoRefillCanMendReachesTheAppOnce(
        hydration: MarfaCore.Hydration, refillFails: MarfaCore.MarfaError?, told: Marfa.MarfaError
    ) async throws {
        let core = Self.stale()
        core.state.withLock {
            $0.hydration = hydration
            $0.hydrateFails = refillFails
        }
        let copy = Self.copy(core)
        let heard = Heard(copy.changes())
        core.change(0, .watchFailed(reason: Self.agedOut, cursor: "3"))
        try await eventually("the stop reached the app") { heard.stops == [stopped(told)] }
        try await Task.sleep(for: .milliseconds(500))
        #expect(heard.stops == [stopped(told)])
        #expect(core.state.withLock { $0.hydrations.count } == (refillFails == nil ? 0 : 1))
        await copy.close()
    }
}
