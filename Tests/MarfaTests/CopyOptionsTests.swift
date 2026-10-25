import MarfaCore
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct CopyOptions {
    @Test func pinChangesDoNotGiveAStreamStoppedByItsCredentialANewPlace() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let heard = Heard(copy.changes())
        core.change(
            0, MarfaCore.Change.watchFailed(reason: .Unauthorized(code: "invalid_key", message: "refused"), cursor: "3")
        )
        try await eventually("the credential stopped the watch") { heard.stops.count == 1 }
        _ = try await copy.pin("outside")
        _ = try await copy.unpin("outside")
        #expect(core.places.count == 1)
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
}
