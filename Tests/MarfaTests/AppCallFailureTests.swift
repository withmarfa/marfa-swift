import Foundation
import MarfaCore
import Testing

@testable import Marfa

/// What the connection says when the app's own catch-up or hydration fails.
@Suite(.timeLimit(.minutes(1)))
struct AnAppCallThatFails {
    typealias Fault = (core: MarfaCore.MarfaError, error: Marfa.MarfaError)

    /// Faults that prove something of the server or the copy, and are not transient or a key refusal.
    static let faults: [Fault] = [
        (.Store(message: "damaged"), .store(message: "damaged")),
        (.Decoding(message: "garbled"), .decoding(message: "garbled")),
        (.NoCatalog(message: "none"), .noCatalog(message: "none")),
        (
            .Server(status: 400, code: "bad_request", message: "no"),
            .server(status: 400, code: "bad_request", message: "no")
        ),
        (
            .WrongServer(expected: "a", got: "b", message: "m"),
            .wrongServer(expected: "a", got: "b", message: "m")
        ),
    ]

    private func followingCopy(_ core: FakeCore, _ clock: ManualClock) async throws -> (WorkingCopy, Updates) {
        let copy = ALifecycle.copy(core, clock)
        let updates = Updates(copy.updates())
        try await eventually("following") { updates.connection == .following }
        return (copy, updates)
    }

    @Test(arguments: faults)
    func stopsAFollowingCopyUntilACatchUpSucceeds(fault: Fault) async throws {
        let core = FakeCore.writer()
        let clock = ManualClock()
        let (copy, updates) = try await followingCopy(core, clock)

        core.state.withLock { $0.catchUpFails = fault.core }
        await #expect(throws: fault.error) { try await copy.catchUp() }
        try await eventually("stopped") { updates.connection == .stopped(fault.error) }
        #expect(try await ALifecycle.wait(clock, after: 0) == .seconds(300))

        // A server event does not show the copy following: only a catch-up that succeeds does.
        core.change(0, ALifecycle.applied("a"))
        try await eventually("the event's row was named") { updates.namedItems.contains("a") }
        #expect(updates.connection == .stopped(fault.error))

        core.state.withLock { $0.catchUpFails = nil }
        clock.advance(by: .seconds(300))
        try await eventually("following once the slow retry succeeded") { updates.connection == .following }
        await copy.close()
    }

    @Test func stoppedByAnAppCallFollowsAgainWhenTheAppsOwnCatchUpSucceeds() async throws {
        let core = FakeCore.writer()
        let clock = ManualClock()
        let (copy, updates) = try await followingCopy(core, clock)

        core.state.withLock { $0.catchUpFails = .Store(message: "damaged") }
        await #expect(throws: Marfa.MarfaError.store(message: "damaged")) { try await copy.catchUp() }
        try await eventually("stopped") { updates.connection == .stopped(.store(message: "damaged")) }

        core.state.withLock { $0.catchUpFails = nil }
        _ = try await copy.catchUp()
        try await eventually("following") { updates.connection == .following }
        try await eventually("the slow retry was dropped") { clock.waiting == 0 }
        await copy.close()
    }

    @Test func stopsAFollowingCopyWhenTheAppsHydrationFails() async throws {
        let core = FakeCore.writer()
        let (copy, updates) = try await followingCopy(core, ManualClock())

        core.state.withLock { $0.hydrateFails = .Decoding(message: "garbled") }
        await #expect(throws: Marfa.MarfaError.decoding(message: "garbled")) {
            try await copy.hydrate(types: ["app.test.entry"], tier: .all)
        }
        try await eventually("stopped") { updates.connection == .stopped(.decoding(message: "garbled")) }
        await copy.close()
    }

    @Test(arguments: faults)
    func tellsACopyWithoutAHydrationWhyItNeedsOne(fault: Fault) async throws {
        let core = FakeCore.writer()
        core.state.withLock {
            $0.hydration = .never
            $0.hydrationCompletes = true
        }
        let clock = ManualClock()
        let copy = ALifecycle.copy(core, clock)
        let updates = Updates(copy.updates())
        try await eventually("waiting for a hydration") { updates.connection == .needsHydration(nil) }

        core.state.withLock { $0.hydrateFails = fault.core }
        await #expect(throws: fault.error) { try await copy.hydrate(types: ["app.test.entry"], tier: .all) }
        try await eventually("needs a hydration, and why") { updates.connection == .needsHydration(fault.error) }
        #expect(clock.waiting == 0, "a copy that needs a hydration was asked again")
        #expect(ALifecycle.catchUps(core) == 0)

        core.state.withLock { $0.hydrateFails = nil }
        _ = try await copy.hydrate(types: ["app.test.entry"], tier: .all)
        try await eventually("following") { updates.connection == .following }
        await copy.close()
    }

    @Test func aServerThatAnswersAsAnotherOneShowsAsAConnectionOnTheFirstCall() async throws {
        let wrong = Marfa.MarfaError.wrongServer(expected: "a", got: "b", message: "m")
        // A copy that holds a hydration is caught up as updates begin.
        let hydrated = FakeCore.writer()
        hydrated.state.withLock { $0.catchUpFails = .WrongServer(expected: "a", got: "b", message: "m") }
        let copy = ALifecycle.copy(hydrated, ManualClock())
        let updates = Updates(copy.updates())
        try await eventually("stopped") { updates.connection == .stopped(wrong) }
        await copy.close()
    }

    @Test(arguments: [
        MarfaCore.MarfaError.Canceled(message: "canceled")
    ])
    func changesNothingWhenTheCallEndsWithoutProvingAnything(fault: MarfaCore.MarfaError) async throws {
        let core = FakeCore.writer()
        let clock = ManualClock()
        let (copy, updates) = try await followingCopy(core, clock)
        let before = updates.all.count

        core.state.withLock { $0.catchUpFails = fault }
        await #expect(throws: (any Error).self) { try await copy.catchUp() }
        #expect(copy.lifecycle.connection == .following)
        try await Task.sleep(for: .milliseconds(100))
        #expect(updates.all.count == before)
        #expect(clock.waiting == 0)
        await copy.close()
    }

    @Test(arguments: [
        Marfa.MarfaError.keyChanging(message: "m"), .canceled(message: "m"), .closed(message: "m"),
        .invalid(message: "m"), .unknownType(message: "m"), .validation(code: "validation_error", message: "m"),
    ])
    func changesNothingForAnErrorThatProvesNothingOfTheServerOrTheCopy(error: Marfa.MarfaError) async throws {
        let core = FakeCore.writer()
        let clock = ManualClock()
        let (copy, updates) = try await followingCopy(core, clock)

        copy.lifecycle.failed(error)
        #expect(copy.lifecycle.connection == .following)
        copy.lifecycle.failed(error, epoch: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(updates.connection == .following)
        #expect(clock.waiting == 0)
        await copy.close()
    }

    @Test func leavesARefusedKeyAlone() async throws {
        let core = FakeCore.writer()
        let (copy, updates) = try await followingCopy(core, ManualClock())
        let refusal = Marfa.MarfaError.unauthorized(code: "unauthorized", message: "no")
        core.change(0, .watchFailed(reason: .Unauthorized(code: "unauthorized", message: "no"), cursor: "3"))
        try await eventually("key refused") { updates.connection == .keyRefused(refusal) }

        copy.lifecycle.failed(Marfa.MarfaError.store(message: "damaged"))
        #expect(copy.lifecycle.connection == .keyRefused(refusal))
        await copy.close()
    }
}
