import Foundation
import MarfaCoreNames
import Testing

@testable import Marfa

private func stopped(_ error: Marfa.MarfaError) -> Marfa.Change {
    Marfa.Change(origin: .stopped(error), itemId: nil, edgeId: nil)
}

private func refreshed(_ refresh: Marfa.Change.Refresh) -> Marfa.Change {
    Marfa.Change(origin: .refreshed(refresh), itemId: nil, edgeId: nil)
}

private func saved(_ version: Int64) -> Marfa.Change {
    Marfa.Change(origin: .saved(dataVersion: version), itemId: nil, edgeId: nil)
}

@Suite(.timeLimit(.minutes(1)))
struct Changes {
    @Test func aWriteIsToldToEveryStreamHeldAndNoneAfterItIsLetGo() async throws {
        let feed = Feed(core: FakeCore.writer(), source: .none)
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
        let feed = Feed(core: FakeCore.writer(), source: .none)
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

    /// A follow the core refuses, here for want of a hydration, is told to
    /// every stream and to one taken after, and local writes go on being
    /// told.
    @Test func aFollowThatStopsIsToldAndLocalWritesGoOn() async throws {
        let copy = try await WorkingCopy.open(
            store: temporaryStore(), server: Server(url: URL(string: "http://127.0.0.1:9")!, key: "k"))
        var heard = copy.changes().makeAsyncIterator()
        guard case .stopped(.noCursor) = await heard.next()?.origin else {
            Issue.record("the refused follow was not told")
            return
        }
        var later = copy.changes().makeAsyncIterator()
        guard case .stopped(.noCursor) = await later.next()?.origin else {
            Issue.record("a stream taken after the follow stopped was not told it had")
            return
        }
        copy.feed.announce(write(.addTag, item: "n1"))
        #expect(await heard.next()?.origin == .local(.addTag))
        #expect(await later.next()?.origin == .local(.addTag))
        try await bounded("close") { await copy.close() }
    }

    @Test func oneFollowFeedsEveryStream() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(core: core, hasServer: true)
        let first = Heard(copy.changes())
        let second = Heard(copy.changes())
        #expect(core.follows.count == 1)
        core.change(0, CoreChange(event: "item.created", itemId: "n1", edgeId: nil, cursor: "7"))
        let told = Marfa.Change(origin: .server(event: "item.created", cursor: "7"), itemId: "n1", edgeId: nil)
        try await eventually("both streams were told") { first.all == [told] && second.all == [told] }
        try await bounded("close") { await copy.close() }
    }

    @Test func aServerChangeCarriesItsCursorAndEdge() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(core: core, hasServer: true)
        let heard = Heard(copy.changes())
        core.change(0, CoreChange(event: "edge.created", itemId: "a", edgeId: "e1", cursor: "42"))
        let told = Marfa.Change(origin: .server(event: "edge.created", cursor: "42"), itemId: "a", edgeId: "e1")
        try await eventually("the change was told") { heard.all == [told] }
        try await bounded("close") { await copy.close() }
    }

    /// The core lets go of its stream only as a follow ends, so a follow
    /// started before then is refused.
    @Test func aNewFollowStartsOnlyOnceTheLastHasEnded() async throws {
        let core = FakeCore.writer()
        let feed = Feed(core: core, source: .follow)
        let (_, first) = AsyncStream<Marfa.Change>.makeStream()
        feed.remove(try #require(feed.add(first)))
        let (stream, second) = AsyncStream<Marfa.Change>.makeStream()
        _ = try #require(feed.add(second))
        let heard = Heard(stream)
        #expect(core.follows.count == 1, "a follow started while the last still held the stream")
        try await eventually("a follow started once the last ended") { core.follows.count == 2 }
        #expect(core.follows[0].ended)
        #expect(core.follows[1].holdsStream)
        try await Task.sleep(for: .milliseconds(200))
        #expect(heard.stops.isEmpty)
        // The witness: a follow that fails on its own is told.
        core.fail(1, with: .Network(message: "gone"))
        try await eventually("the failure was told") { heard.stops == [stopped(.network(message: "gone"))] }
        try await bounded("close") { await feed.close() }
    }

    @Test func whatAnEarlierFollowSaysLateIsIgnored() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(core: core, hasServer: true)
        Heard(copy.changes()).stop()
        try await eventually("the first follow ended") { core.follows.first?.ended == true }
        let heard = Heard(copy.changes())
        try await eventually("a second follow started") { core.follows.count == 2 }

        core.endAgain(0, with: .Network(message: "late"))
        core.change(0, CoreChange(event: "item.created", itemId: "late", edgeId: nil, cursor: "1"))
        core.change(1, CoreChange(event: "item.created", itemId: "current", edgeId: nil, cursor: "2"))
        try await eventually("the running follow's change was told") { !heard.all.isEmpty }
        #expect(heard.all.map(\.itemId) == ["current"])
        // Still the running follow: letting the stream go stops it.
        heard.stop()
        try await eventually("the running follow was stopped") { core.follows[1].stopped }
    }

    @Test func anErrorFromAFollowAlreadyStoppedIsNotTold() async throws {
        let core = FakeCore.writer()
        let feed = Feed(core: core, source: .follow)
        let (_, first) = AsyncStream<Marfa.Change>.makeStream()
        feed.remove(try #require(feed.add(first)))
        let (stream, second) = AsyncStream<Marfa.Change>.makeStream()
        _ = try #require(feed.add(second))
        let heard = Heard(stream)
        core.fail(0, with: .Network(message: "as it stopped"))
        try await eventually("the next follow started") { core.follows.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(heard.stops.isEmpty, "a follow already stopped told its error")
        // The witness: a follow that fails on its own is told.
        core.fail(1, with: .Network(message: "on its own"))
        try await eventually("the failure was told") { heard.stops == [stopped(.network(message: "on its own"))] }
        try await bounded("close") { await feed.close() }
    }

    @Test func aFollowThatFailedStartsAgainOnlyOnAHydrationOrACatchUp() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(core: core, hasServer: true)
        let first = Heard(copy.changes())
        core.fail(0, with: .Unauthorized(code: "invalid_key", message: "refused"))
        let refused = stopped(.unauthorized(code: "invalid_key", message: "refused"))
        try await eventually("the failure was told") { first.all == [refused] }

        let second = Heard(copy.changes())
        try await eventually("a stream taken after was told at once") { second.all == [refused] }
        #expect(core.follows.count == 1, "a new stream started the failed follow again")

        _ = try await bounded("the catch-up") { try await copy.catchUp() }
        #expect(core.follows.count == 2)
        core.fail(1, with: .Network(message: "gone"))
        try await eventually("the second failure was told") { first.stops.count == 2 }
        _ = try await bounded("the hydration") { try await copy.hydrate(types: ["core.note"], tier: .feed) }
        #expect(core.follows.count == 3)
        try await bounded("close") { await copy.close() }
    }

    /// The fake refuses a hydration or a catch-up while a follow holds the
    /// stream, so either one run across a follow fails here.
    @Test func aHydrationAndACatchUpRunWithNoFollowAndStartItAgain() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(core: core, hasServer: true)
        let heard = Heard(copy.changes())
        _ = try await bounded("the hydration") { try await copy.hydrate(types: ["core.note"], tier: .feed) }
        #expect(core.follows.count == 2)
        #expect(core.follows[0].ended)
        _ = try await bounded("the catch-up") { try await copy.catchUp() }
        #expect(core.follows.count == 3)
        core.state.withLock { $0.caughtUp.applied = 2 }
        _ = try await bounded("the catch-up") { try await copy.catchUp() }
        #expect(core.follows.count == 4)
        // The catch-up that applied nothing was not told.
        try await eventually("the hydration and the catch-up that applied events were told") {
            heard.all == [refreshed(.hydrated), refreshed(.caughtUp)]
        }
        try await bounded("close") { await copy.close() }
    }

    @Test func aDrainThatRecordedVerdictsIsToldAndStartsNothing() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(core: core, hasServer: true)
        let heard = Heard(copy.changes())
        core.fail(0, with: .Network(message: "gone"))
        _ = try await copy.queue.drain()
        core.state.withLock {
            $0.drained.verdicts = [
                CoreDrainVerdict(
                    id: "q", kind: .createItem, itemId: "n1", verdict: .accepted, refusals: 0, replayed: false)
            ]
        }
        _ = try await copy.queue.drain()
        // The drain that recorded nothing was not told.
        try await eventually("the drain that recorded a verdict was told") {
            heard.all == [stopped(.network(message: "gone")), refreshed(.drained)]
        }
        #expect(core.follows.count == 1, "a drain started the failed follow again")
        // The witness: a catch-up does start it again.
        _ = try await bounded("the catch-up") { try await copy.catchUp() }
        try await eventually("a catch-up started the follow again") { core.follows.count == 2 }
        try await bounded("close") { await copy.close() }
    }

    @Test func closingReturnsOnceTheFollowHasEnded() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(core: core, hasServer: true)
        let heard = Heard(copy.changes())
        #expect(core.follows.count == 1)
        try await bounded("close") { await copy.close() }
        #expect(core.follows[0].ended, "close returned while the follow still held the store")
        withExtendedLifetime(heard) {}
    }

    @Test func closingAReaderReturnsOnceItsWatchHasEnded() async throws {
        let core = FakeCore.reader()
        let copy = WorkingCopy(core: core, hasServer: false)
        let heard = Heard(copy.changes())
        let gate = core.holdNextRead()
        try await eventually("the watch is reading") { core.aReadWasHeld }
        let closing = Task {
            await copy.close()
            return Date.now
        }
        try await Task.sleep(for: .milliseconds(300))
        let released = Date.now
        gate.signal()
        let closed = try await bounded("close") { await closing.value }
        #expect(closed >= released, "close returned while the watch was still reading")
        withExtendedLifetime(heard) {}
    }

    @Test func lettingGoOfTheLastStreamStopsTheWatch() async throws {
        let core = FakeCore.reader()
        let copy = WorkingCopy(core: core, hasServer: false)
        let heard = Heard(copy.changes())
        let watch = try #require(copy.feed.watchTask)
        #expect(!watch.isCancelled)
        heard.stop()
        try await eventually("the stream was let go") { copy.feed.count == 0 }
        #expect(watch.isCancelled)
        try await bounded("the watch's end") { await watch.value }
        #expect(copy.feed.watchTask == nil)
    }

    /// The version a reader's first `changes()` reads can wait on the store,
    /// and holds nothing else of the copy while it does.
    @Test func aReaderListeningWhileTheStoreIsBusyHoldsNothingElse() async throws {
        let core = FakeCore.reader()
        let copy = WorkingCopy(core: core, hasServer: false)
        let gate = core.holdNextRead()
        let listening = Task.detached { Heard(copy.changes()) }
        try await eventually("the first read is held") { core.aReadWasHeld }
        _ = try await bounded("the feed's count", within: 1) { copy.feed.count }
        gate.signal()
        let heard = try await bounded("changes()") { await listening.value }
        core.save()
        try await eventually("the save was told") { !heard.all.isEmpty }
        try await bounded("close") { await copy.close() }
    }

    @Test func aSaveMadeAsSoonAsAReaderListensIsTold() async throws {
        let core = FakeCore.reader()
        let copy = WorkingCopy(core: core, hasServer: false)
        let heard = Heard(copy.changes())
        core.save()
        try await eventually("the save was told", within: 1) { !heard.all.isEmpty }
        #expect(heard.all == [saved(1)])
        try await bounded("close") { await copy.close() }
    }

    @Test func aWatchThatFailsIsToldAndStaysStopped() async throws {
        let core = FakeCore.reader()
        let copy = WorkingCopy(core: core, hasServer: false)
        let first = Heard(copy.changes())
        let watch = try #require(copy.feed.watchTask)
        core.state.withLock { $0.readsFail = .Store(message: "gone") }
        let failed = stopped(.store(message: "gone"))
        try await eventually("the failure was told") { first.all == [failed] }
        try await bounded("the watch's end") { await watch.value }
        let second = Heard(copy.changes())
        try await eventually("a stream taken after was told at once") { second.all == [failed] }
        #expect(copy.feed.watchTask == nil, "a new stream started the failed watch again")
        // The store reads again, so a watch started now would run on.
        core.state.withLock { $0.readsFail = nil }
        _ = try await bounded("the hydration") { try await copy.hydrate(types: ["core.note"], tier: .feed) }
        _ = try await bounded("the catch-up") { try await copy.catchUp() }
        #expect(copy.feed.watchTask == nil, "a hydration or catch-up started a reader's failed watch again")
        try await bounded("close") { await copy.close() }
    }

    /// A watch moves no cursor, so a hydration or catch-up leaves it running.
    @Test func aReadersWatchRunsOnThroughAHydrationAndACatchUp() async throws {
        let core = FakeCore.reader()
        let copy = WorkingCopy(core: core, hasServer: false)
        let heard = Heard(copy.changes())
        let watch = try #require(copy.feed.watchTask)
        _ = try await bounded("the hydration") { try await copy.hydrate(types: ["core.note"], tier: .feed) }
        _ = try await bounded("the catch-up") { try await copy.catchUp() }
        #expect(copy.feed.watchTask == watch)
        #expect(!watch.isCancelled)
        try await bounded("close") { await copy.close() }
        withExtendedLifetime(heard) {}
    }

    @Test func aWatchStoppedMidReadTellsNothing() async throws {
        let core = FakeCore.reader()
        let copy = WorkingCopy(core: core, hasServer: false)
        let first = Heard(copy.changes())
        let gate = core.holdNextRead()
        try await eventually("the first watch is reading") { core.aReadWasHeld }
        first.stop()
        try await eventually("the first stream was let go") { copy.feed.count == 0 }
        core.save()
        let second = Heard(copy.changes())
        gate.signal()
        try await Task.sleep(for: .milliseconds(600))
        #expect(second.all.isEmpty, "the stopped watch told what it read after it was stopped")
        // The witness: the running watch tells the next save.
        core.save()
        try await eventually("the running watch told the next save") { !second.all.isEmpty }
        #expect(second.all == [saved(2)])
        try await bounded("close") { await copy.close() }
    }
}
