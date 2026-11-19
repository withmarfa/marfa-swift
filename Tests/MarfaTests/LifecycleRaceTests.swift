import Dispatch
import Foundation
import MarfaCore
import Synchronization
import Testing

@testable import Marfa

/// Holds the first drain result that reaches a copy's lifecycle, until released.
final class HeldReport: Sendable {
    private let entered = Mutex(false)
    private let gate = DispatchSemaphore(value: 0)

    init(on lifecycle: Lifecycle) {
        lifecycle.reporting.withLock { hook in
            hook = { [self] in
                let first = entered.withLock { held in
                    defer { held = true }
                    return !held
                }
                if first { gate.wait() }
            }
        }
    }

    var isHeld: Bool { entered.withLock { $0 } }
    func release() { gate.signal() }
}

/// Holds the first drain that asks for its key once it holds a lease, until released.
final class HeldLease: Sendable {
    private let entered = Mutex(false)
    private let gate = DispatchSemaphore(value: 0)

    init(on lifecycle: Lifecycle) {
        lifecycle.leasing.withLock { hook in
            hook = { [self] in
                let first = entered.withLock { held in
                    defer { held = true }
                    return !held
                }
                if first { gate.wait() }
            }
        }
    }

    var isHeld: Bool { entered.withLock { $0 } }
    func release() { gate.signal() }
}

/// A keychain in memory that holds the first read of a key after `holdNextRead()`, and can lose a sign-in.
final class GatedKeychain: KeychainBackend {
    private let items = Mutex<[String: Data]>([:])
    private let armed = Mutex(false)
    private let entered = Mutex(false)
    private let gate = DispatchSemaphore(value: 0)

    var keychain: Keychain { Keychain(backend: self) }
    var isHeld: Bool { entered.withLock { $0 } }
    func holdNextRead() { armed.withLock { $0 = true } }
    func release() { gate.signal() }

    func loseEverySignIn() { items.withLock { $0.removeAll() } }

    private func name(_ service: String, _ account: String) -> String { "\(service)\n\(account)" }

    func data(service: String, account: String) throws -> Data? {
        let held = armed.withLock { armed in
            defer { armed = false }
            return armed
        }
        if held {
            entered.withLock { $0 = true }
            gate.wait()
        }
        return items.withLock { $0[name(service, account)] }
    }

    func put(_ data: Data, service: String, account: String) throws {
        items.withLock { $0[name(service, account)] = data }
    }

    func delete(service: String, account: String) throws {
        items.withLock { _ = $0.removeValue(forKey: name(service, account)) }
    }

    func holds(service: String, account: String?) throws -> Bool {
        items.withLock { items in items.keys.contains { $0.hasPrefix("\(service)\n\(account ?? "")") } }
    }

    func add(label: String, service: String, account: String) throws -> Bool { false }
    func label(service: String, account: String) throws -> String? { nil }
    func delete(label: String, service: String, account: String) throws {}
    func relabel(from: String, to: String, service: String, account: String) throws -> Bool { false }
}

private let unauthorized = MarfaCore.MarfaError.Unauthorized(code: "unauthorized", message: "no", server: nil)

private func isRefused(_ connection: CopyConnection?) -> Bool {
    if case .keyRefused? = connection { true } else { false }
}

private func report(
    stopped: String? = nil, undelivered: UInt64 = 0
) -> MarfaCore.DrainReport {
    MarfaCore.DrainReport(
        answered: 0, held: 0, undelivered: undelivered, unsent: 0, unmade: 0, unavailable: nil, verdicts: [],
        stopped: stopped, unclaimedSources: [], retryAfterSeconds: nil)
}

/// How a core's drain ends in the key's refusal: a report that says it stopped, or an error.
enum DrainRefusal: CaseIterable, CustomStringConvertible {
    case reported
    case thrown

    var description: String { self == .reported ? "a report that stopped" : "a thrown refusal" }

    func script(_ core: FakeCore) {
        core.state.withLock { state in
            switch self {
            case .reported: state.drained = report(stopped: "unauthorized")
            case .thrown: state.drainFails = unauthorized
            }
        }
    }
}

// Serialized because a held report blocks the thread that delivers it, and every test runs at once.
@Suite(.timeLimit(.minutes(1)), .serialized)
struct ADrainUnderAnOldKey {
    private struct Following {
        let old: FakeCore
        let new: FakeCore
        let copy: WorkingCopy
        let clock: ManualClock
        let updates: Updates
    }

    private static func following() async throws -> Following {
        let old = FakeCore.writer()
        let new = FakeCore.writer()
        let clock = ManualClock()
        let copy = WorkingCopy(
            holder: CoreHolder(old, reopen: { _ in new }), hasServer: true, refillClock: .init(clock))
        let updates = Updates(copy.updates())
        try await eventually("following") { updates.connection == .following }
        return Following(old: old, new: new, copy: copy, clock: clock, updates: updates)
    }

    /// Replaces the key and waits until the new key's catch-up has the copy following.
    private static func replaceKey(_ run: Following) async throws {
        try await bounded("use") { try await run.copy.use(.stub("new-key")) }
        try await eventually("following under the new key") {
            run.new.state.withLock { $0.catchUps } == 1 && run.copy.lifecycle.connection == .following
        }
    }

    @Test(arguments: DrainRefusal.allCases)
    func theAppsDrainThatEndedUnderTheOldKeyDoesNotRefuseTheNewOne(refusal: DrainRefusal) async throws {
        let run = try await Self.following()
        refusal.script(run.old)
        let held = HeldReport(on: run.copy.lifecycle)
        let draining = Task { try? await run.copy.queue.drain() }
        try await eventually("the old key's result is held") { held.isHeld }

        try await Self.replaceKey(run)
        held.release()
        _ = try await bounded("drain") { await draining.value }

        #expect(run.copy.lifecycle.connection == .following, "the old key's refusal marked the new key refused")
        await run.copy.close()
    }

    /// The drain holds a lease on the old core from before the key change began, and asks for its key after the
    /// copy has started to change it.
    @Test(arguments: DrainRefusal.allCases)
    func aDrainLeasedTheOldCoreBeforeTheKeyChangeBeganDoesNotRefuseTheNewKeyWhateverItAsksLate(
        refusal: DrainRefusal
    ) async throws {
        let run = try await Self.following()
        refusal.script(run.old)
        let lease = HeldLease(on: run.copy.lifecycle)
        let held = HeldReport(on: run.copy.lifecycle)
        let draining = Task { try? await run.copy.queue.drain() }
        try await eventually("the drain holds its lease") { lease.isHeld }
        let changing = Task { try await run.copy.use(.stub("new-key")) }
        try await eventually("the key change began") { run.copy.lifecycle.keyEpoch == -1 }

        lease.release()
        try await eventually("the old key's result is held") { held.isHeld }
        try await bounded("use") { try await changing.value }
        try await eventually("following under the new key") {
            run.new.state.withLock { $0.catchUps } == 1 && run.copy.lifecycle.connection == .following
        }
        held.release()
        _ = try await bounded("drain") { await draining.value }
        try await Task.sleep(for: .milliseconds(200))

        #expect(run.copy.lifecycle.connection == .following, "the old key's refusal marked the new key refused")
        await run.copy.close()
    }

    /// A retry refused for a key change that then fails to begin is not a retry that ended: no key changed.
    @Test func aRetryDrainRefusedWhileAKeyChangeFailsBeforeItBeginsIsRetriedAgain() async throws {
        let run = try await Self.following()
        await run.old.change(0, .queueDrained(report: report(undelivered: 1), cursor: "2"))
        try await eventually("a drain waits") { run.clock.waiting > 0 }

        let home = URL(string: "http://127.0.0.1:1")!
        let signIns = GatedKeychain()
        let credential = try Credential.keeping(
            accessToken: "at-1", refreshToken: nil, scopes: [], server: home, keychain: signIns.keychain,
            service: "com.example.tests", session: .shared)
        let server = try Server(url: home, credential: credential)
        signIns.loseEverySignIn()
        signIns.holdNextRead()
        let changing = Task { try await run.copy.use(server) }
        try await eventually("the key change waits for the keychain") { signIns.isHeld }

        run.clock.advance(by: .seconds(5))
        try await eventually("the retry fired") { run.clock.waiting == 0 }
        try await Task.sleep(for: .milliseconds(200))
        signIns.release()
        await #expect(throws: SignInError.notSignedIn) { try await changing.value }

        try await eventually("a next retry waits", within: 5) { run.clock.waiting > 0 }
        await run.copy.close()
    }

    @Test(arguments: DrainRefusal.allCases)
    func theSameRefusalWithNoKeyChangeMarksTheCopyRefused(refusal: DrainRefusal) async throws {
        let run = try await Self.following()
        refusal.script(run.old)
        _ = try? await run.copy.queue.drain()
        try await eventually("key refused") { isRefused(run.updates.connection) }
        await run.copy.close()
    }

    @Test func aRetryDrainThatEndedUnderTheOldKeyDoesNotRefuseTheNewOne() async throws {
        let run = try await Self.following()
        await run.old.change(0, .queueDrained(report: report(undelivered: 1), cursor: "2"))
        try await eventually("a drain waits") { run.clock.waiting > 0 }
        DrainRefusal.reported.script(run.old)
        let held = HeldReport(on: run.copy.lifecycle)
        run.clock.advance(by: .seconds(5))
        try await eventually("the old key's result is held") { held.isHeld }

        try await Self.replaceKey(run)
        held.release()
        try await eventually("the retry's task ended") { run.old.state.withLock { $0.drains } == 1 }
        try await Task.sleep(for: .milliseconds(200))

        #expect(run.copy.lifecycle.connection == .following, "the old key's refusal marked the new key refused")
        await run.copy.close()
    }

    private static let staleEvents: [(String, MarfaCore.Change)] = [
        ("a drain that stopped", .queueDrained(report: report(stopped: "unauthorized"), cursor: "9")),
        ("a drain that failed", .queueNotDrained(error: unauthorized, cursor: "9")),
        ("a watch that failed", .watchFailed(reason: unauthorized, cursor: "9")),
    ]

    /// The core's stream hands the lifecycle what an old key's watch told, after the key changed.
    @Test(arguments: staleEvents.map(\.0))
    func whatAnOldKeysStreamToldAfterTheKeyChangedDoesNotRefuseTheNewOne(name: String) async throws {
        let event = try #require(Self.staleEvents.first { $0.0 == name }).1
        let run = try await Self.following()
        let held = HeldReport(on: run.copy.lifecycle)
        // The lifecycle's stream stops on the first result, so the next one waits behind it.
        await run.old.change(0, .queueDrained(report: report(), cursor: "2"))
        try await eventually("the stream is held") { held.isHeld }
        await run.old.change(0, event)

        try await Self.replaceKey(run)
        try await eventually("the new core's place") { run.new.places.count == 1 }
        await run.new.change(0, ALifecycle.applied("after"))
        held.release()
        try await eventually("the stream was read to its end") { run.updates.namedItems.contains("after") }

        #expect(run.copy.lifecycle.connection == .following, "the old key's stream marked the new key refused")
        await run.copy.close()
    }

    @Test func whatTheStreamToldWithNoKeyChangeStillMarksTheCopyRefused() async throws {
        let run = try await Self.following()
        await run.old.change(0, .queueDrained(report: report(stopped: "unauthorized"), cursor: "9"))
        try await eventually("key refused") { isRefused(run.updates.connection) }
        await run.copy.close()
    }

    /// A drain the app began while the old key was in use, and which waited for room until the key had changed, ran
    /// under the new key, and its result is the new key's.
    @Test func anAppsDrainThatWaitedForRoomUntilTheKeyChangedIsTheNewKeysResult() async throws {
        let (old, new) = (FakeCore.writer(), FakeCore.writer())
        let clock = ManualClock()
        let room = CoreQueue(limit: 2)
        let copy = WorkingCopy(
            holder: CoreHolder(old, reopen: { _ in new }, blocking: room), hasServer: true, refillClock: .init(clock))
        let updates = Updates(copy.updates())
        try await eventually("following") { updates.connection == .following }
        new.state.withLock { $0.drained = report(undelivered: 1) }
        let inCore = new.holdNextDrain()
        defer { inCore.signal() }

        let fillers = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
        defer { for filler in fillers { filler.signal() } }
        for filler in fillers { room.perform { filler.wait() } }
        let draining = Task { try? await copy.queue.drain() }
        try await eventually("the drain waits for room") { room.waitingCount == 1 }

        try await bounded("use") { try await copy.use(.stub("new-key")) }
        for filler in fillers { filler.signal() }
        try await eventually("the drain holds the new core") { new.aDrainWasHeld }
        try await eventually("following under the new key") {
            new.state.withLock { $0.catchUps } == 1 && copy.lifecycle.connection == .following
        }
        #expect(clock.waiting == 0, "something else was already waiting on the clock")
        inCore.signal()
        _ = try await bounded("drain") { await draining.value }

        try await eventually("a retry waits for the writes the drain left", within: 5) { clock.waiting > 0 }
        await copy.close()
    }

    /// What the core's stream told, still being handed to the lifecycle when the key change ends, is the old key's.
    @Test(arguments: [true, false])
    func aResultFromTheStreamStillBeingDeliveredWhenTheKeyChangeEndsDoesNotRefuseTheNewKey(thrown: Bool) async throws {
        let run = try await Self.following()
        let held = HeldReport(on: run.copy.lifecycle)
        await run.old.change(
            0,
            thrown
                ? .queueNotDrained(error: unauthorized, cursor: "9")
                : .queueDrained(report: report(stopped: "unauthorized"), cursor: "9"))
        try await eventually("the result is held") { held.isHeld }

        try await Self.replaceKey(run)
        held.release()
        try await Task.sleep(for: .milliseconds(300))

        #expect(run.copy.lifecycle.connection == .following, "the old key's result marked the new key refused")
        await run.copy.close()
    }
}
