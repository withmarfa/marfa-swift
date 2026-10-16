import MarfaCore
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct CopyOptions {
    @Test func pinChangesDoNotRestartAFollowStoppedByItsCredential() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let heard = Heard(copy.changes())
        core.fail(0, with: .Unauthorized(code: "invalid_key", message: "refused"))
        try await eventually("the credential stopped the follow") { heard.stops.count == 1 }
        _ = try await copy.pin("outside")
        _ = try await copy.unpin("outside")
        #expect(core.follows.count == 1)
        await copy.close()
    }

    @Test func hydrationCarriesEdgeTypesAndReportsThem() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let report = try await copy.hydrate(types: ["core.note"], tier: .all, edgeTypes: ["attached-to"])
        let options = try #require(core.state.withLock { $0.hydrationOptions })
        #expect(options.types == ["core.note"])
        #expect(options.tier == .all)
        #expect(report.tier == .all)
        #expect(options.edgeTypes == ["attached-to"])
        #expect(report.edgeTypes == options.edgeTypes)
        await copy.close()
    }

    @Test(arguments: [
        (Marfa.SliceTier.library, MarfaCore.SliceTier.library), (.feed, .feed), (.all, .all),
    ])
    func hydrationCarriesEachSliceTier(tier: Marfa.SliceTier, core tierInCore: MarfaCore.SliceTier)
        async throws
    {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let report = try await copy.hydrate(types: ["core.note"], tier: tier)
        #expect(core.state.withLock { $0.hydrationOptions }?.tier == tierInCore)
        #expect(report.tier == tier)
        await copy.close()
    }

    @Test func hydrationPreservesRegistrationRefusals() async throws {
        let core = FakeCore.writer()
        core.state.withLock {
            $0.registrationRefusals = [
                MarfaCore.UnregisteredType(id: "app.entry", code: "forbidden", message: "metadata.types:write required")
            ]
        }
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let report = try await copy.hydrate(types: ["core.note"], tier: .library)
        #expect(
            report.unregisteredTypes == [
                Marfa.UnregisteredType(id: "app.entry", code: "forbidden", message: "metadata.types:write required")
            ])
        await copy.close()
    }

    @Test func pinsCarryTheirItemAndNotifyListeners() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let heard = Heard(copy.changes())
        #expect(try await copy.pin("outside") == Marfa.PinReport(pinned: true, wasPinned: false))
        #expect(try await copy.pin("outside") == Marfa.PinReport(pinned: true, wasPinned: true))
        #expect(core.state.withLock { $0.pins } == ["outside"])
        #expect(try await copy.unpin("outside") == Marfa.PinReport(pinned: false, wasPinned: true))
        #expect(try await copy.unpin("outside") == Marfa.PinReport(pinned: false, wasPinned: false))
        try await eventually("pin changes were told") { heard.all.count == 4 }
        #expect(
            heard.all.map(\.origin) == [
                .refreshed(.pinned), .refreshed(.pinned), .refreshed(.unpinned), .refreshed(.unpinned),
            ])
        #expect(heard.all.map(\.itemId) == ["outside", "outside", "outside", "outside"])
        await copy.close()
    }

    @Test func theFollowSaysTypedWhenTheServerGoesAndComesBack() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let heard = Heard(copy.changes())
        core.change(
            0,
            MarfaCore.Change.serverUnreachable(
                reason: .RateLimited(code: "rate_limited", message: "slow down", retryAfterSeconds: 7), cursor: "3"))
        core.change(0, MarfaCore.Change.serverReachable(cursor: "3"))
        try await eventually("both were told") { heard.all.count == 2 }
        #expect(
            heard.all.map(\.origin) == [
                .serverUnreachable(.rateLimited(code: "rate_limited", message: "slow down", retryAfterSeconds: 7)),
                .serverReachable,
            ])
        await copy.close()
    }

    @Test(arguments: ["catch-up", "hydration"])
    func aRecoveryDrainsWhatWaitedOnceAndLeavesTheNextOutageToBeTold(recovery: String) async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let heard = Heard(copy.changes())
        func count(_ kind: (Marfa.Change.Origin) -> Bool) -> Int { heard.all.filter { kind($0.origin) }.count }
        let queueDrained = { (origin: Marfa.Change.Origin) in if case .queueDrained = origin { true } else { false } }
        let unreachable = { (origin: Marfa.Change.Origin) in if case .serverUnreachable = origin { true } else { false }
        }
        let recover = {
            if recovery == "catch-up" {
                _ = try await copy.catchUp()
            } else {
                _ = try await copy.hydrate(types: ["core.note"], tier: .library)
            }
        }
        try await eventually("the follow started") { core.follows.count == 1 }
        let gone = MarfaCore.MarfaError.Network(message: "refused")
        core.change(0, MarfaCore.Change.serverUnreachable(reason: gone, cursor: "3"))
        try await eventually("the server's going was told") { count(unreachable) == 1 }

        // The call proves the server is reachable, so the copy drains what waited
        // itself: the follow it restarts is told only what the app was told, and
        // starts no drain of its own.
        let verdict = MarfaCore.DrainVerdict(
            id: "q", kind: .createItem, itemId: "n1", edgeId: nil, verdict: .accepted, refusals: 0, replayed: false)
        core.state.withLock {
            $0.drained = MarfaCore.DrainReport(
                answered: 1, held: 0, undelivered: 0, unsent: 0, unmade: 0, unavailable: nil, verdicts: [verdict],
                stopped: nil, unclaimedSources: [], retryAfterSeconds: nil)
        }
        try await recover()
        try await eventually("the follow started again") { core.follows.count == 2 }
        try await eventually("the drain was told") { count(queueDrained) == 1 }
        #expect(!core.follows[1].toldUnreachable, "the follow would hide the next outage from the app")
        core.change(1, MarfaCore.Change.serverUnreachable(reason: gone, cursor: "3"))
        try await eventually("the next outage was told") { count(unreachable) == 2 }

        // The witness: nothing waits, so a second recovery tells no drain.
        core.state.withLock {
            $0.drained = MarfaCore.DrainReport(
                answered: 0, held: 0, undelivered: 0, unsent: 0, unmade: 0, unavailable: nil, verdicts: [],
                stopped: nil, unclaimedSources: [], retryAfterSeconds: nil)
        }
        try await recover()
        try await Task.sleep(for: .milliseconds(200))
        #expect(count(queueDrained) == 1)
        await copy.close()
    }

    @Test(arguments: Errors.cases)
    func anUnreachableServerIsToldWithTheErrorItCameWith(coreError: MarfaCore.MarfaError, expected: Marfa.MarfaError)
        async throws
    {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let heard = Heard(copy.changes())
        core.change(0, MarfaCore.Change.serverUnreachable(reason: coreError, cursor: "3"))
        try await eventually("the server's going was told") { heard.all.count == 1 }
        #expect(heard.all.map(\.origin) == [.serverUnreachable(expected)])
        await copy.close()
    }

    @Test func theServersStateOutlastsAFollowAndIsToldOnce() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let heard = Heard(copy.changes())
        try await eventually("the follow started") { core.follows.count == 1 }
        let gone = MarfaCore.MarfaError.Network(message: "refused")
        core.change(0, MarfaCore.Change.serverUnreachable(reason: gone, cursor: "3"))
        try await eventually("the server's going was told") { heard.all.count == 1 }

        // A catch-up that fails restarts the follow, which is told it, and a
        // second word of the same is not told again.
        core.state.withLock { $0.catchUpFails = gone }
        _ = try? await copy.catchUp()
        try await eventually("the follow started again") { core.follows.count == 2 }
        #expect(core.follows[1].toldUnreachable, "a new follow was not told the server was unreachable")
        core.change(1, MarfaCore.Change.serverUnreachable(reason: gone, cursor: "3"))

        // A stream added meanwhile is told where the server stands.
        let late = Heard(copy.changes())
        try await eventually("the late stream was told") { late.all.count == 1 }
        #expect(late.all.map(\.origin) == [.serverUnreachable(.network(message: "refused"))])

        // A catch-up that reaches the server says it came back, once.
        core.state.withLock { $0.catchUpFails = nil }
        _ = try await copy.catchUp()
        try await eventually("the server's return was told") { heard.all.count == 2 }
        core.change(core.follows.count - 1, MarfaCore.Change.serverReachable(cursor: "3"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(heard.all.map(\.origin) == [.serverUnreachable(.network(message: "refused")), .serverReachable])
        #expect(core.follows.last?.toldUnreachable == false)
        await copy.close()
    }
}
