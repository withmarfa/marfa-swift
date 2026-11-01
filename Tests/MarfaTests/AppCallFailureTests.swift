import Foundation
import MarfaCore
import Synchronization
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

    // MARK: A transient failure of an app's call

    @Test func aTransientFailureOfAnAppCallLeavesAStoppedCopyStopped() async throws {
        let core = FakeCore.writer()
        let clock = ManualClock()
        let (copy, updates) = try await followingCopy(core, clock)
        let stopped = Marfa.MarfaError.store(message: "damaged")

        core.state.withLock { $0.catchUpFails = .Store(message: "damaged") }
        await #expect(throws: stopped) { try await copy.catchUp() }
        try await eventually("stopped") { updates.connection == .stopped(stopped) }

        core.state.withLock { $0.catchUpFails = ALifecycle.offline }
        await #expect(throws: (any Error).self) { try await copy.catchUp() }
        core.change(0, ALifecycle.applied("a"))
        try await eventually("the event's row was named") { updates.namedItems.contains("a") }
        #expect(updates.connection == .stopped(stopped))
        #expect(copy.lifecycle.connection == .stopped(stopped))
        await copy.close()
    }

    @Test func aTransientFailureOfAnAppCallLeavesACopyThatNeedsAHydrationAlone() async throws {
        let core = FakeCore.writer()
        core.state.withLock { $0.hydration = .never }
        let clock = ManualClock()
        let copy = ALifecycle.copy(core, clock)
        let updates = Updates(copy.updates())
        try await eventually("waiting for a hydration") { updates.connection == .needsHydration(nil) }

        core.state.withLock { $0.catchUpFails = ALifecycle.offline }
        await #expect(throws: (any Error).self) { try await copy.catchUp() }
        core.change(0, ALifecycle.applied("a"))
        try await eventually("the event's row was named") { updates.namedItems.contains("a") }
        #expect(copy.lifecycle.connection == .needsHydration(nil))
        #expect(clock.waiting == 0, "a copy that needs a hydration was asked again")
        await copy.close()
    }

    // MARK: Before the first status read lands

    @Test func aHydrationThatFailedBeforeTheFirstStatusReadLandedKeepsItsErrorAndDropsTheRetry() async throws {
        let core = FakeCore.writer()
        let status = DispatchSemaphore(value: 0)
        core.state.withLock {
            $0.hydration = .never
            $0.statusGate = status
            $0.hydrateFails = .WrongServer(expected: "a", got: "b", message: "m")
        }
        let clock = ManualClock()
        let copy = ALifecycle.copy(core, clock)
        let updates = Updates(copy.updates())
        try await eventually("the first status read began") { core.state.withLock { $0.statusGate == nil } }

        let wrong = Marfa.MarfaError.wrongServer(expected: "a", got: "b", message: "m")
        await #expect(throws: wrong) { try await copy.hydrate(types: ["app.test.entry"], tier: .all) }
        try await eventually("stopped by the call") { updates.connection == .stopped(wrong) }
        try await eventually("the slow retry was asked for") { clock.requested.contains(.seconds(300)) }

        status.signal()
        try await eventually("needs a hydration, and why") { updates.connection == .needsHydration(wrong) }
        try await eventually("the slow retry was dropped") { clock.waiting == 0 }
        #expect(ALifecycle.catchUps(core) == 0)
        await copy.close()
    }

    @Test func aHydrationThatCompletedBeforeTheFirstStatusReadLandedStaysFollowing() async throws {
        let core = FakeCore.writer()
        let status = DispatchSemaphore(value: 0)
        core.state.withLock {
            $0.hydration = .inProgress
            $0.hydrationCompletes = true
            $0.statusGate = status
        }
        let copy = ALifecycle.copy(core, ManualClock())
        let updates = Updates(copy.updates())
        try await eventually("the first status read began") { core.state.withLock { $0.statusGate == nil } }

        _ = try await copy.hydrate(types: ["app.test.entry"], tier: .all)
        try await eventually("following") { updates.connection == .following }

        status.signal()
        try await eventually("the held status read returned") { core.state.withLock { $0.heldStatuses == 1 } }
        copy.lifecycle.whileLocked {}
        #expect(copy.lifecycle.connection == .following)
        await copy.close()
    }

    @Test func aStatusReadTakenBeforeAHydrationAndAStopDoesNotStrandTheCopy() async throws {
        let core = FakeCore.writer()
        let status = DispatchSemaphore(value: 0)
        core.state.withLock {
            $0.hydration = .never
            $0.hydrationCompletes = true
            $0.statusGate = status
        }
        let clock = ManualClock()
        let copy = ALifecycle.copy(core, clock)
        let updates = Updates(copy.updates())
        try await eventually("the first status read began") { core.state.withLock { $0.statusGate == nil } }

        _ = try await copy.hydrate(types: ["app.test.entry"], tier: .all)
        try await eventually("following") { updates.connection == .following }
        let stopped = Marfa.MarfaError.store(message: "damaged")
        core.state.withLock { $0.catchUpFails = .Store(message: "damaged") }
        await #expect(throws: stopped) { try await copy.catchUp() }
        try await eventually("stopped") { updates.connection == .stopped(stopped) }

        status.signal()
        try await eventually("the held status read returned") { core.state.withLock { $0.heldStatuses == 1 } }
        copy.lifecycle.whileLocked {}
        #expect(copy.lifecycle.connection == .stopped(stopped))
        #expect(clock.waiting == 1, "the slow retry was dropped")
        await copy.close()
    }

    // MARK: Calls that began before a key change

    @Test(arguments: [
        MarfaCore.MarfaError.Store(message: "old core"),
        .Unauthorized(code: "unauthorized", message: "old key"),
    ])
    func aCallThatBeganBeforeAKeyChangeSaysNothingOfTheNewKeysCopy(fault: MarfaCore.MarfaError) async throws {
        let core = FakeCore.writer()
        let clock = ManualClock()
        let (copy, updates) = try await followingCopy(core, clock)
        let app = DispatchSemaphore(value: 0)
        let pull = DispatchSemaphore(value: 0)
        core.state.withLock { $0.catchUpScript = [(app, fault), (pull, nil)] }

        let calling = Task { try await copy.catchUp() }
        try await eventually("the call is in the core") { core.state.withLock { $0.catchUpScript.count == 1 } }
        copy.lifecycle.keyWillChange()
        copy.lifecycle.keyChanged()
        app.signal()
        await #expect(throws: (any Error).self) { try await calling.value }

        try await eventually("the new key's catch-up is in the core") {
            core.state.withLock { $0.catchUpScript.isEmpty }
        }
        #expect(copy.lifecycle.connection == .connecting)
        #expect(clock.waiting == 0)
        pull.signal()
        try await eventually("following") { updates.connection == .following }
        await copy.close()
    }

    // MARK: A stopped copy's own retry

    @Test func aStoppedCopyStaysStoppedWhenItsOwnRetryFailsOnTheNetwork() async throws {
        let core = FakeCore.writer()
        let clock = ManualClock()
        let (copy, updates) = try await followingCopy(core, clock)
        let stopped = Marfa.MarfaError.store(message: "damaged")

        core.state.withLock { $0.catchUpFails = .Store(message: "damaged") }
        await #expect(throws: stopped) { try await copy.catchUp() }
        try await eventually("stopped") { updates.connection == .stopped(stopped) }
        #expect(try await ALifecycle.wait(clock, after: 0) == .seconds(300))

        let before = ALifecycle.catchUps(core)
        core.state.withLock { $0.catchUpFails = ALifecycle.offline }
        clock.advance(by: .seconds(300))
        try await eventually("the retry ran") { ALifecycle.catchUps(core) == before + 1 }
        #expect(try await ALifecycle.wait(clock, after: 1) == .seconds(300), "the retry was not asked for again")

        core.change(0, ALifecycle.applied("a"))
        try await eventually("the event's row was named") { updates.namedItems.contains("a") }
        #expect(copy.lifecycle.connection == .stopped(stopped))
        #expect(updates.connection == .stopped(stopped))

        core.state.withLock { $0.catchUpFails = nil }
        clock.advance(by: .seconds(300))
        try await eventually("following once a retry succeeded") { updates.connection == .following }
        await copy.close()
    }

    @Test func aNewRunForgetsTheStopOfTheRunBefore() async throws {
        let core = FakeCore.writer()
        let clock = ManualClock()
        let (copy, updates) = try await followingCopy(core, clock)
        let stopped = Marfa.MarfaError.store(message: "damaged")

        core.state.withLock { $0.catchUpFails = .Store(message: "damaged") }
        await #expect(throws: stopped) { try await copy.catchUp() }
        try await eventually("stopped") { updates.connection == .stopped(stopped) }
        updates.cancel()
        try await eventually("the follow was let go") { copy.feed.count == 0 && clock.waiting == 0 }

        // The new run's first catch-up fails on the network: it is offline and asks again, not stuck connecting.
        core.state.withLock { $0.catchUpFails = ALifecycle.offline }
        let again = Updates(copy.updates())
        try await eventually("offline") {
            if case .offline = again.connection { return true }
            return false
        }
        #expect(try await ALifecycle.wait(clock, after: 1) > .zero, "the offline catch-up was not asked again")
        again.cancel()
        await copy.close()
    }

    // MARK: A call that starts during a key change

    @Test func aCallThatBeganDuringAKeyChangeSaysNothingOfTheNewKeysCopy() async throws {
        let core = FakeCore.writer()
        let clock = ManualClock()
        let (copy, updates) = try await followingCopy(core, clock)
        let app = DispatchSemaphore(value: 0)
        let pull = DispatchSemaphore(value: 0)
        core.state.withLock { $0.catchUpScript = [(app, .Store(message: "old core")), (pull, nil)] }

        copy.lifecycle.keyWillChange()
        let calling = Task { try await copy.catchUp() }
        try await eventually("the call is in the core") { core.state.withLock { $0.catchUpScript.count == 1 } }
        copy.lifecycle.keyChanged()
        app.signal()
        await #expect(throws: (any Error).self) { try await calling.value }

        try await eventually("the new key's catch-up is in the core") {
            core.state.withLock { $0.catchUpScript.isEmpty }
        }
        #expect(copy.lifecycle.connection == .connecting)
        #expect(clock.waiting == 0)
        pull.signal()
        try await eventually("following") { updates.connection == .following }
        await copy.close()
    }

    // MARK: Order

    @Test func aCallDoesNotRunBeforeTheCallBeforeItHasReported() async throws {
        let core = FakeCore.writer()
        let (copy, updates) = try await followingCopy(core, ManualClock())
        let lifecycle = copy.lifecycle
        let first = DispatchSemaphore(value: 0)
        core.state.withLock { $0.catchUpScript = [(first, nil), (nil, .Store(message: "second"))] }
        let a = Task { try await copy.catchUp() }
        try await eventually("the first is in the core") { core.state.withLock { $0.catchUpScript.count == 1 } }
        let b = Task { try await copy.catchUp() }
        try await Task.sleep(for: .milliseconds(20))
        let before = ALifecycle.catchUps(core)

        // While the lifecycle is busy, the first call ends: the second must still wait for it to report.
        let held = Mutex(false)
        let release = Mutex(false)
        DispatchQueue.global().async {
            lifecycle.whileLocked {
                held.withLock { $0 = true }
                while !release.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.005) }
            }
        }
        try await eventually("the lock is held") { held.withLock { $0 } }
        first.signal()
        try await eventually("the first ran") { ALifecycle.catchUps(core) == before + 1 }
        try await Task.sleep(for: .milliseconds(150))
        #expect(ALifecycle.catchUps(core) == before + 1, "the second call ran before the first had reported")
        release.withLock { $0 = true }

        _ = try await a.value
        await #expect(throws: (any Error).self) { try await b.value }
        #expect(copy.lifecycle.connection == .stopped(.store(message: "second")))
        #expect(updates.connection == .stopped(.store(message: "second")))
        await copy.close()
    }
}
