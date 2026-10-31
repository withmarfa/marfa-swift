import Dispatch
import Foundation
import MarfaCore
import Synchronization
import Testing

@testable import Marfa

/// Collects what one sequence of updates delivers.
final class Updates: Sendable {
    private final class Log: Sendable {
        let updates = Mutex<[CopyUpdate]>([])
        let ended = Mutex(false)
    }

    private let log: Log
    private let listening: Task<Void, Never>

    init(_ sequence: CopyUpdates) {
        let log = Log()
        self.log = log
        listening = Task {
            for await update in sequence { log.updates.withLock { $0.append(update) } }
            log.ended.withLock { $0 = true }
        }
    }

    var all: [CopyUpdate] { log.updates.withLock { $0 } }
    var connection: CopyConnection? { all.last?.connection }
    var ended: Bool { log.ended.withLock { $0 } }

    /// Every item an update named, in order.
    var namedItems: [String] {
        all.flatMap { update -> [String] in
            if case .parts(let parts) = update.reread { parts.rows.items } else { [] }
        }
    }

    func cancel() { listening.cancel() }
}

@Suite(.timeLimit(.minutes(1)))
struct ALifecycle {
    static let offline = MarfaCore.MarfaError.Network(message: "offline")

    static func copy(_ core: FakeCore, _ clock: ManualClock) -> WorkingCopy {
        WorkingCopy(holder: CoreHolder(core), hasServer: true, refillClock: .init(clock))
    }

    /// The length of the wait asked for after `count` earlier ones, once it is being waited.
    static func wait(_ clock: ManualClock, after count: Int) async throws -> Duration {
        try await eventually("a wait was asked for") { clock.requested.count > count && clock.waiting > 0 }
        return clock.requested[count]
    }

    static func catchUps(_ core: FakeCore) -> Int { core.state.withLock { $0.catchUps } }

    static func report(undelivered: UInt64, retryAfterSeconds: UInt64?) -> MarfaCore.DrainReport {
        MarfaCore.DrainReport(
            answered: 0, held: 0, undelivered: undelivered, unsent: 0, unmade: 0, unavailable: nil, verdicts: [],
            stopped: nil, unclaimedSources: [], retryAfterSeconds: retryAfterSeconds)
    }

    static func applied(_ itemId: String, _ cursor: Int = 1) -> MarfaCore.Change {
        .applied(event: "item.updated", itemId: itemId, edgeId: nil, cursor: "\(cursor)")
    }

    // MARK: Starting

    @Test func aCopyThatReachesItsServerIsFollowingOnceItsFirstCatchUpSucceeds() async throws {
        let core = FakeCore.writer()
        let copy = Self.copy(core, ManualClock())
        let updates = Updates(copy.updates())
        try await eventually("following") { updates.connection == .following }
        #expect(updates.all.first?.reread == .everything)
        #expect(Self.catchUps(core) == 1)
        // The core does not record when it last heard from the server yet.
        #expect(updates.all.last?.lastSynced == nil)
        #expect(try await copy.status().lastSynced == nil)
        await copy.close()
    }

    @Test func aCopyWithoutAServerIsLocalAndAsksNothing() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false, refillClock: .init(ManualClock()))
        let updates = Updates(copy.updates())
        try await eventually("the first update") { !updates.all.isEmpty }
        #expect(updates.connection == .local)
        #expect(Self.catchUps(core) == 0)
        await copy.close()
    }

    @Test func aCopyWithNoHydrationWaitsForOneAndFollowsOnceItCompletes() async throws {
        let core = FakeCore.writer()
        core.state.withLock {
            $0.hydration = .never
            $0.hydrationCompletes = true
        }
        let copy = Self.copy(core, ManualClock())
        let updates = Updates(copy.updates())
        try await eventually("waiting for a hydration") { updates.connection == .needsHydration(nil) }
        #expect(Self.catchUps(core) == 0)
        _ = try await copy.hydrate(types: ["app.test.entry"], tier: .all)
        try await eventually("following") { updates.connection == .following }
        await copy.close()
    }

    // MARK: Restarting

    @Test func aServerAbsentForLongIsAskedFurtherApartAndFollowedOnlyOnceACatchUpSucceeds() async throws {
        let core = FakeCore.writer()
        core.state.withLock { $0.catchUpFails = Self.offline }
        let clock = ManualClock()
        let copy = Self.copy(core, clock)
        let updates = Updates(copy.updates())
        try await eventually("offline") { updates.connection == .offline(.network(message: "offline")) }

        var waits: [Duration] = []
        for attempt in 0..<9 {
            let wait = try await Self.wait(clock, after: attempt)
            waits.append(wait)
            clock.advance(by: wait)
            try await eventually("the catch-up was made again") { Self.catchUps(core) == attempt + 2 }
        }
        #expect(waits == [5, 10, 20, 40, 80, 160, 300, 300, 300].map { Duration.seconds($0) })
        #expect(!updates.all.contains { $0.connection == .following }, "a copy that never reached its server followed")

        core.state.withLock { $0.catchUpFails = nil }
        clock.advance(by: try await Self.wait(clock, after: 9))
        try await eventually("following once a catch-up succeeded") { updates.connection == .following }

        // A follow that ran five minutes since it last failed starts its waits again from the first.
        clock.advance(by: .seconds(300))
        core.fail(0, with: .Io(message: "disk"))
        try await eventually("offline again") { updates.connection == .offline(.io(message: "disk")) }
        #expect(try await Self.wait(clock, after: 10) == .seconds(5))
        clock.advance(by: .seconds(5))
        try await eventually("following again") { updates.connection == .following }
        #expect(core.places.count == 2, "the stream the core ended was not taken again")
        await copy.close()
    }

    @Test func aRateLimitIsWaitedOutForAtLeastTheTimeItNames() async throws {
        let core = FakeCore.writer()
        core.state.withLock {
            $0.catchUpFails = .RateLimited(code: "rate_limited", message: "slow down", retryAfterSeconds: 120)
        }
        let clock = ManualClock()
        let copy = Self.copy(core, clock)
        let updates = Updates(copy.updates())
        #expect(try await Self.wait(clock, after: 0) == .seconds(120))
        clock.advance(by: .seconds(119))
        #expect(Self.catchUps(core) == 1)
        core.state.withLock { $0.catchUpFails = nil }
        clock.advance(by: .seconds(1))
        try await eventually("following") { updates.connection == .following }

        // A drain that left writes undelivered goes again, no sooner than its rate limit asks.
        core.state.withLock { $0.drained = Self.report(undelivered: 1, retryAfterSeconds: 60) }
        core.change(0, .queueDrained(report: Self.report(undelivered: 1, retryAfterSeconds: 60), cursor: "2"))
        #expect(try await Self.wait(clock, after: 1) == .seconds(60))
        clock.advance(by: .seconds(60))
        try await eventually("drained again") { core.state.withLock { $0.drains } == 1 }
        #expect(try await Self.wait(clock, after: 2) == .seconds(60))
        core.state.withLock { $0.drained = Self.report(undelivered: 0, retryAfterSeconds: nil) }
        clock.advance(by: .seconds(60))
        try await eventually("drained once more") { core.state.withLock { $0.drains } == 2 }
        try await eventually("no drain waits") { clock.waiting == 0 }
        await copy.close()
    }

    @Test func aRefusedKeyIsNotAskedAgainUntilAKeyChangeWhichCatchesUpAtOnce() async throws {
        let old = FakeCore.writer()
        let new = FakeCore.writer()
        let clock = ManualClock()
        let copy = WorkingCopy(
            holder: CoreHolder(old, reopen: { _ in new }), hasServer: true, refillClock: .init(clock))
        let updates = Updates(copy.updates())
        try await eventually("following") { updates.connection == .following }

        old.change(0, .watchFailed(reason: .Unauthorized(code: "unauthorized", message: "no"), cursor: "3"))
        try await eventually("key refused") {
            updates.connection == .keyRefused(.unauthorized(code: "unauthorized", message: "no"))
        }
        #expect(clock.waiting == 0, "a refused key was asked again")

        try await copy.useKey("new-key")
        try await eventually("following with the new key") { updates.connection == .following }
        #expect(Self.catchUps(new) == 1)
        await copy.close()
    }

    @Test func aKeyChangeWhileWaitingToAskAgainAsksAtOnceWithTheNewKey() async throws {
        let old = FakeCore.writer()
        old.state.withLock { $0.catchUpFails = Self.offline }
        let new = FakeCore.writer()
        let clock = ManualClock()
        let copy = WorkingCopy(
            holder: CoreHolder(old, reopen: { _ in new }), hasServer: true, refillClock: .init(clock))
        let updates = Updates(copy.updates())
        _ = try await Self.wait(clock, after: 0)

        try await copy.useKey("new-key")
        try await eventually("following with the new key") { updates.connection == .following }
        #expect(Self.catchUps(new) == 1)
        try await eventually("the old wait ended") { clock.waiting == 0 }
        clock.advance(by: .seconds(300))
        #expect(Self.catchUps(old) == 1, "the old key's wait asked again")
        await copy.close()
    }

    @Test func aStopThatMayNotMendIsAskedEveryFiveMinutesAndAServerEventDoesNotShowItFollowing() async throws {
        let core = FakeCore.writer()
        let clock = ManualClock()
        let copy = Self.copy(core, clock)
        let updates = Updates(copy.updates())
        try await eventually("following") { updates.connection == .following }

        core.change(0, .watchFailed(reason: .Server(status: 400, code: "bad_request", message: "no"), cursor: "3"))
        let stopped = CopyConnection.stopped(.server(status: 400, code: "bad_request", message: "no"))
        try await eventually("stopped") { updates.connection == stopped }
        #expect(try await Self.wait(clock, after: 0) == .seconds(300))

        core.change(0, Self.applied("a"))
        try await eventually("the event's row was named") { updates.namedItems.contains("a") }
        #expect(updates.connection == stopped, "a server event showed a stopped follow as following")

        clock.advance(by: .seconds(300))
        try await eventually("following once the catch-up succeeded") { updates.connection == .following }
        #expect(Self.catchUps(core) == 2)
        await copy.close()
    }

    @Test func aCopyWhoseStreamTheCoreEndedStillHearsItsOwnWritesAndJoinsTheWatchAgainOnceACatchUpSucceeds()
        async throws
    {
        let core = FakeCore.writer()
        let clock = ManualClock()
        let copy = Self.copy(core, clock)
        var updates = copy.updates().makeAsyncIterator()
        var update = await updates.next()
        while update?.connection != .following { update = await updates.next() }

        core.fail(0, with: .Io(message: "disk"))
        while update?.connection != .offline(.io(message: "disk")) { update = await updates.next() }
        try await eventually("the stream was let go") { copy.feed.count == 0 }

        let own: [(Marfa.Change.Origin, Reread)] = [
            (.local(.createItem), .parts(Reread.Parts(queue: true))),
            (.refreshed(.viewWritten), .parts(Reread.Parts(views: true))),
            (.refreshed(.forgotten), .parts(Reread.Parts(queue: true))),
        ]
        for (origin, reread) in own {
            copy.announce(Marfa.Change(origin: origin, itemId: nil, edgeId: nil))
            let heard = try #require(await updates.next(), "\(origin)")
            #expect(heard.reread == reread, "\(origin)")
            #expect(heard.connection == .offline(.io(message: "disk")))
        }

        clock.advance(by: try await Self.wait(clock, after: 0))
        while update?.connection != .following { update = await updates.next() }
        try await eventually("the watch was joined again") { core.places.count == 2 && copy.feed.count == 1 }
        copy.announce(Marfa.Change(origin: .refreshed(.catalog), itemId: nil, edgeId: nil))
        #expect(await updates.next()?.reread == .parts(Reread.Parts(catalog: true)))
        await copy.close()
    }

    @Test func aReaderWhoseStreamTheCoreEndedIsStoppedAndTakesItAgainAfterAWait() async throws {
        let core = FakeCore.reader()
        let clock = ManualClock()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false, refillClock: .init(clock))
        let updates = Updates(copy.updates())
        try await eventually("watching the writer's saves") { updates.connection == .local && core.places.count == 1 }

        core.state.withLock { $0.watchRefused = .Io(message: "disk") }
        core.fail(0, with: .Io(message: "disk"))
        try await eventually("stopped") { updates.connection == .stopped(.io(message: "disk")) }
        #expect(try await Self.wait(clock, after: 0) == .seconds(5))
        clock.advance(by: .seconds(5))
        // The watch refused the stream again, so the next wait is longer.
        #expect(try await Self.wait(clock, after: 1) == .seconds(10))
        #expect(updates.connection == .stopped(.io(message: "disk")))

        core.state.withLock { $0.watchRefused = nil }
        let before = updates.all.count
        clock.advance(by: .seconds(10))
        try await eventually("watching again") { updates.connection == .local && core.places.count == 2 }
        // A save made while no stream was held went unseen.
        try await eventually("asked to read everything") {
            updates.all[before...].contains { $0.reread == .everything }
        }
        #expect(copy.feed.count == 1)
        await copy.close()
    }

    @Test func aRefillThatFailsForNowShowsTheCopyOfflineUntilItSucceeds() async throws {
        let core = FakeCore.writer()
        let clock = ManualClock()
        let copy = Self.copy(core, clock)
        let updates = Updates(copy.updates())
        try await eventually("following") { updates.connection == .following }

        core.state.withLock {
            $0.hydration = .stale
            $0.slice = (["core.note"], .library, [])
            $0.hydrationCompletes = true
            $0.hydrateFails = .Network(message: "offline")
            $0.hydrateFailsFirst = 1
        }
        core.change(0, .watchFailed(reason: ARefill.agedOut, cursor: "3"))
        try await eventually("offline") { updates.connection == .offline(.network(message: "offline")) }
        #expect(updates.all.contains { $0.connection == .connecting })
        try await ARefill.letWaitsPass(on: clock, until: updates.connection == .following)
        #expect(core.state.withLock { $0.hydrations.count } == 2)
        await copy.close()
    }

    @Test func catchUpsThatSucceedAtOnceAfterAFaultTakeOneStreamThatTheLastConsumerLetsGo() async throws {
        for round in 0..<60 {
            let core = FakeCore.writer()
            let copy = Self.copy(core, ManualClock())
            let updates = Updates(copy.updates())
            try await eventually("following") { updates.connection == .following }
            core.fail(0, with: .Io(message: "disk"))
            try await eventually("the stream was let go") { copy.feed.count == 0 }

            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 { group.addTask { _ = try? await copy.catchUp() } }
            }
            try await eventually("one stream is held", within: 5) { copy.feed.count == 1 }
            #expect(updates.connection == .following, "round \(round)")

            updates.cancel()
            try await eventually("round \(round): the last consumer let the stream go", within: 5) {
                copy.feed.count == 0
            }
            await copy.close()
        }
    }

    @Test func aSecondActivationNeverTellsThePreviousRunsConnection() async throws {
        let core = FakeCore.writer()
        let clock = ManualClock()
        let copy = Self.copy(core, clock)
        let first = Updates(copy.updates())
        try await eventually("following") { first.connection == .following }
        first.cancel()
        try await eventually("the follow was let go") { copy.feed.count == 0 }
        core.state.withLock { $0.catchUpFails = Self.offline }

        for round in 0..<200 {
            let told = await withTaskGroup(of: CopyConnection?.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        var updates = copy.updates().makeAsyncIterator()
                        return await updates.next()?.connection
                    }
                }
                return await group.reduce(into: [CopyConnection?]()) { $0.append($1) }
            }
            #expect(!told.contains(.following), "round \(round)")
            try await eventually("the follow was let go") { copy.feed.count == 0 }
        }
        await copy.close()
    }

    // MARK: Ending

    @Test func aCloseWhileWaitingToAskAgainEndsTheWaitAndTheSequence() async throws {
        let core = FakeCore.writer()
        core.state.withLock { $0.catchUpFails = Self.offline }
        let clock = ManualClock()
        let copy = Self.copy(core, clock)
        let updates = Updates(copy.updates())
        _ = try await Self.wait(clock, after: 0)

        await copy.close()
        try await eventually("the sequence ended") { updates.ended }
        #expect(updates.connection == .closed)
        try await eventually("the wait ended") { clock.waiting == 0 }
        clock.advance(by: .seconds(300))
        #expect(Self.catchUps(core) == 1)

        let late = Updates(copy.updates())
        try await eventually("a sequence asked for after the close ended") { late.ended }
        #expect(late.all.map(\.connection) == [.closed])
    }

    @Test func aCanceledConsumerLetsTheFollowAndItsWaitGo() async throws {
        let core = FakeCore.writer()
        core.state.withLock { $0.catchUpFails = Self.offline }
        let clock = ManualClock()
        let copy = Self.copy(core, clock)
        let updates = Updates(copy.updates())
        _ = try await Self.wait(clock, after: 0)

        updates.cancel()
        try await eventually("the follow was let go") { copy.feed.count == 0 && clock.waiting == 0 }
        #expect(core.places[0].stopped)
        clock.advance(by: .seconds(300))
        #expect(Self.catchUps(core) == 1)

        let again = Updates(copy.updates())
        try await eventually("a new consumer starts again") { Self.catchUps(core) == 2 }
        _ = again
        await copy.close()
    }

    // MARK: Coalescing

    @Test func aBurstOfEventsWhileTheAppReadsArrivesAsOneUpdateNamingEachRowOnce() async throws {
        let core = FakeCore.writer()
        let copy = Self.copy(core, ManualClock())
        var updates = copy.updates().makeAsyncIterator()
        var update = await updates.next()
        #expect(update?.reread == .everything)
        while update?.connection != .following { update = await updates.next() }

        for n in 0..<10_000 { core.change(0, Self.applied("i\(n % 50)", n)) }
        let burst = try #require(await updates.next())
        guard case .parts(let parts) = burst.reread else {
            Issue.record("the burst asked to read everything: \(burst.reread)")
            return
        }
        #expect(Set(parts.rows.items) == Set((0..<50).map { "i\($0)" }))
        #expect(parts.rows.items.count == 50)

        core.change(0, Self.applied("j", 10_000))
        let next = try #require(await updates.next())
        #expect(next.reread == .parts(Reread.Parts(rows: ChangedRows(items: ["j"]))))
        await copy.close()
    }

    @Test func aBurstNamingMoreRowsThanTheLimitAsksToReadEverything() async throws {
        let core = FakeCore.writer()
        let copy = Self.copy(core, ManualClock())
        var updates = copy.updates().makeAsyncIterator()
        var update = await updates.next()
        while update?.connection != .following { update = await updates.next() }

        for n in 0..<10_000 { core.change(0, Self.applied("i\(n)", n)) }
        #expect(await updates.next()?.reread == .everything)
        await copy.close()
    }

    @Test func eachChangeAsksForThePartItChanged() async throws {
        let core = FakeCore.writer()
        let copy = Self.copy(core, ManualClock())
        var updates = copy.updates().makeAsyncIterator()
        var update = await updates.next()
        while update?.connection != .following { update = await updates.next() }

        let told: [(Marfa.Change.Origin, Reread)] = [
            (.refreshed(.viewWritten), .parts(Reread.Parts(views: true))),
            (.refreshed(.catalog), .parts(Reread.Parts(catalog: true))),
            (.refreshed(.forgotten), .parts(Reread.Parts(queue: true))),
            (.local(.createItem), .parts(Reread.Parts(queue: true))),
            (.saved(dataVersion: 2), .everything),
        ]
        for (origin, reread) in told {
            copy.announce(Marfa.Change(origin: origin, itemId: nil, edgeId: nil))
            #expect(await updates.next()?.reread == reread, "\(origin)")
        }
        await copy.close()
    }

    // MARK: Progress

    @Test func aRunningHydrationTellsItsProgressAndAsksToReadTheRowsThatArrived() async throws {
        let core = FakeCore.writer()
        let gate = DispatchSemaphore(value: 0)
        core.state.withLock {
            $0.hydrateGate = gate
            $0.itemsExpected = 10
            $0.itemsListed = 2
        }
        let clock = ManualClock()
        let copy = Self.copy(core, clock)
        let updates = Updates(copy.updates())
        try await eventually("following") { updates.connection == .following }

        let hydrating = Task { try await copy.hydrate(types: ["app.test.entry"], tier: .all) }
        try await eventually("the progress is told") { updates.all.last?.fill == FillProgress(listed: 2, expected: 10) }
        #expect(updates.all.last?.fill?.fraction == 0.2)
        let before = updates.all.count
        core.state.withLock { $0.itemsListed = 6 }
        try await eventually("the next reading waits") { clock.waiting > 0 }
        clock.advance(by: .milliseconds(500))
        try await eventually("the new progress is told") {
            updates.all.last?.fill == FillProgress(listed: 6, expected: 10)
        }
        #expect(updates.all[before...].contains { $0.reread == .everything })

        gate.signal()
        _ = try await hydrating.value
        try await eventually("the progress is cleared") { updates.all.last?.fill == nil }
        await copy.close()
    }

    @Test func aHydrationIsToldToReadEverythingOnceWhenNoRowArrivedWhileItRan() async throws {
        let core = FakeCore.writer()
        let gate = DispatchSemaphore(value: 0)
        core.state.withLock {
            $0.hydrateGate = gate
            $0.itemsExpected = 10
        }
        let clock = ManualClock()
        let copy = Self.copy(core, clock)
        let updates = Updates(copy.updates())
        try await eventually("following") { updates.connection == .following }
        let before = updates.all.count

        let hydrating = Task { try await copy.hydrate(types: ["app.test.entry"], tier: .all) }
        try await eventually("the progress is told") { updates.all.last?.fill == FillProgress(listed: 0, expected: 10) }
        gate.signal()
        _ = try await hydrating.value
        try await eventually("the progress is cleared") { updates.all.last?.fill == nil }
        try await eventually("the hydration is told") { updates.all[before...].contains { $0.reread == .everything } }
        #expect(updates.all[before...].filter { $0.reread == .everything }.count == 1)
        #expect(updates.all.last?.reread == .everything)
        await copy.close()
    }
}
