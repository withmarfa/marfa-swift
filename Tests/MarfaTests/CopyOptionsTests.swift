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
            MarfaCore.Change(
                event: "server.unreachable", itemId: nil, edgeId: nil, cursor: "3",
                reason: .RateLimited(code: "rate_limited", message: "slow down", retryAfterSeconds: 7)))
        core.change(
            0, MarfaCore.Change(event: "server.reachable", itemId: nil, edgeId: nil, cursor: "3", reason: nil))
        try await eventually("both were told") { heard.all.count == 2 }
        #expect(
            heard.all.map(\.origin) == [
                .serverUnreachable(.rateLimited(code: "rate_limited", message: "slow down", retryAfterSeconds: 7)),
                .serverReachable,
            ])
        await copy.close()
    }

    @Test func theServersStateOutlastsAFollowAndIsToldOnce() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let heard = Heard(copy.changes())
        try await eventually("the follow started") { core.follows.count == 1 }
        let gone = MarfaCore.MarfaError.Network(message: "refused")
        core.change(
            0, MarfaCore.Change(event: "server.unreachable", itemId: nil, edgeId: nil, cursor: "3", reason: gone))
        try await eventually("the server's going was told") { heard.all.count == 1 }

        // A catch-up that fails restarts the follow, which is told it, and a
        // second word of the same is not told again.
        core.state.withLock { $0.catchUpFails = gone }
        _ = try? await copy.catchUp()
        try await eventually("the follow started again") { core.follows.count == 2 }
        #expect(core.follows[1].toldUnreachable, "a new follow was not told the server was unreachable")
        core.change(
            1, MarfaCore.Change(event: "server.unreachable", itemId: nil, edgeId: nil, cursor: "3", reason: gone))

        // A stream added meanwhile is told where the server stands.
        let late = Heard(copy.changes())
        try await eventually("the late stream was told") { late.all.count == 1 }
        #expect(late.all.map(\.origin) == [.serverUnreachable(.network(message: "refused"))])

        // A catch-up that reaches the server says it came back, once.
        core.state.withLock { $0.catchUpFails = nil }
        _ = try await copy.catchUp()
        try await eventually("the server's return was told") { heard.all.count == 2 }
        core.change(
            core.follows.count - 1,
            MarfaCore.Change(event: "server.reachable", itemId: nil, edgeId: nil, cursor: "3", reason: nil))
        try await Task.sleep(for: .milliseconds(100))
        #expect(heard.all.map(\.origin) == [.serverUnreachable(.network(message: "refused")), .serverReachable])
        #expect(core.follows.last?.toldUnreachable == false)
        await copy.close()
    }
}
