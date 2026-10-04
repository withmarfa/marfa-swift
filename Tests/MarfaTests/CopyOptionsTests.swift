import MarfaCoreNames
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
        let report = try await copy.hydrate(types: ["core.note"], tier: .feed, edgeTypes: ["attached-to"])
        let options = try #require(core.state.withLock { $0.hydrationOptions })
        #expect(options.types == ["core.note"])
        #expect(options.tier == .feed)
        #expect(options.edgeTypes == ["attached-to"])
        #expect(report.edgeTypes == options.edgeTypes)
        await copy.close()
    }

    @Test func hydrationPreservesRegistrationRefusals() async throws {
        let core = FakeCore.writer()
        core.state.withLock {
            $0.registrationRefusals = [
                CoreUnregisteredType(id: "app.entry", code: "forbidden", message: "metadata.types:write required")
            ]
        }
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let report = try await copy.hydrate(types: ["core.note"], tier: .library)
        #expect(
            report.unregisteredTypes == [
                UnregisteredType(id: "app.entry", code: "forbidden", message: "metadata.types:write required")
            ])
        await copy.close()
    }

    @Test func pinsCarryTheirItemAndNotifyListeners() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let heard = Heard(copy.changes())
        #expect(try await copy.pin("outside") == PinReport(pinned: true, wasPinned: false))
        #expect(try await copy.pin("outside") == PinReport(pinned: true, wasPinned: true))
        #expect(core.state.withLock { $0.pins } == ["outside"])
        #expect(try await copy.unpin("outside") == PinReport(pinned: false, wasPinned: true))
        #expect(try await copy.unpin("outside") == PinReport(pinned: false, wasPinned: false))
        try await eventually("pin changes were told") { heard.all.count == 4 }
        #expect(
            heard.all.map(\.origin) == [
                .refreshed(.pinned), .refreshed(.pinned), .refreshed(.unpinned), .refreshed(.unpinned),
            ])
        #expect(heard.all.map(\.itemId) == ["outside", "outside", "outside", "outside"])
        await copy.close()
    }

    @Test func anExpiredChangeRetainsItsReason() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let heard = Heard(copy.changes())
        core.change(
            0, CoreChange(event: "copy.expired", itemId: nil, edgeId: nil, cursor: "3", reason: "instance_changed"))
        try await eventually("expiry was told") { heard.all.count == 1 }
        #expect(heard.all.first?.reason == "instance_changed")
        #expect(heard.all.first?.origin == .server(event: "copy.expired", cursor: "3"))
        await copy.close()
    }
}
