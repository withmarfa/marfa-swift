import Foundation
package import MarfaCore
import Synchronization

/// The streams `changes()` hands out.
///
/// Each stream is its own listener in the core's watch, which holds the one
/// source, tells every listener what the server did, and keeps a hydration or
/// catch-up from meeting a follow. The feed adds what the core cannot know: the
/// app's own announcements, the end of every stream when the copy closes, a new
/// place in the watch for each stream when the core is replaced, and the refill
/// of a copy whose cursor the server's event log let go, which the core leaves
/// to its caller.
final class Feed: Sendable {
    /// How soon a refill is tried again.
    ///
    /// At once the first time, then after `first`, doubling up to `most`. A follow that ran for `settle` after a
    /// refill starts again from at once.
    struct RefillPace: Sendable {
        var first: Duration
        var most: Duration
        var settle: Duration

        static let standard = RefillPace(first: .seconds(1), most: .seconds(300), settle: .seconds(300))
    }

    /// The time a refill reads and waits by, so a test can drive it.
    struct RefillClock: Sendable {
        private let reading: @Sendable () -> Duration
        private let waiting: @Sendable (Duration) async throws -> Void

        init<C: Clock>(_ clock: C) where C.Duration == Duration {
            let origin = clock.now
            reading = { origin.duration(to: clock.now) }
            waiting = { try await clock.sleep(for: $0) }
        }

        /// How long the clock has run since this value was made.
        var now: Duration { reading() }

        func sleep(for duration: Duration) async throws { try await waiting(duration) }

        static let continuous = RefillClock(ContinuousClock())
    }

    private struct Refill {
        var running = false
        /// Streams whose `.stopped` waits on the refill, told only where it cannot be made.
        var waiting: Set<UUID> = []
        /// What last stopped the follow, told where the copy turns out not to be one a refill can mend.
        var reason: MarfaError?
        /// The server answered the copy's follow under the reach it was built under, and said its cursor aged out.
        ///
        /// Only then does a refill start by itself: the reach is not exposed, and a hydration under another reach
        /// replaces the copy instead of filling it in place.
        var vouched = false
        /// A refill's own fill was cut off by a failure that mends itself, so a copy left `.inProgress` is its own.
        var unfinished = false
        var attempts = 0
        /// The wait a rate limit named for the next attempt.
        var retryAfter: Duration = .zero
        /// The clock's reading when the last refill's fill ended.
        var filledAt: Duration?
        var task: Task<Void, Never>?
    }

    private struct Stream {
        let continuation: AsyncStream<Change>.Continuation
        /// The stream's place in the core's watch. `nil` before it has one,
        /// while the core is replaced, and after the watch ends it.
        var subscription: MarfaCore.Subscription?
        /// Names the place being taken or held, so a call from one the stream
        /// has left is ignored.
        var registration: Int?
        /// Last told the server is unreachable, which a new place in the watch is given.
        var unreachable = false
        var addedWhileSuspended = false
    }

    private struct State {
        var streams: [UUID: Stream] = [:]
        var closed = false
        /// Holds every stream out of the watch, as a key change does while the
        /// core is replaced.
        var suspends = 0
        /// Counts every suspension, so work begun under one key can tell that another may since have replaced it.
        var suspensions = 0
        var registrations = 0
        /// Places the core has not yet let go; the store is free when none is left.
        var open: Set<Int> = []
        var waitingForEnd: [CheckedContinuation<Void, Never>] = []
        /// Told once the lock is let go; `nil` ends the stream.
        var told: [(AsyncStream<Change>.Continuation, Change?)] = []
        var refill = Refill()
        /// A hydration or catch-up runs; the core runs one at a time and refuses the next `invalid`.
        var filling = false
        var fillWaiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
        /// The hydration that held the turn last, where it completed.
        var lastFill: Fill?
    }

    private struct Fill {
        let types: [String]
        let tier: MarfaCore.SliceTier
        let edgeTypes: [String]
        let report: MarfaCore.HydrateReport
        /// `suspensions` when it began.
        let suspensions: Int
    }

    /// A refill that found the key changed before its fill began.
    private struct KeyChanged: Error {}

    let holder: CoreHolder
    /// Whether the core has a watch to give: a writer with a server, or a reader.
    private let watched: Bool
    private let refillPace: RefillPace
    private let clock: RefillClock
    private let instanceAt: InstanceAt
    private let state = Mutex(State())

    /// The instance that answers at a server's address, as its public description names it.
    typealias InstanceAt = @Sendable (_ origin: String) async throws -> String

    static let instanceAt: InstanceAt = { origin in
        try await background { try Marfa.translated { try MarfaCore.instanceDescription(url: origin).instanceId } }
    }

    init(
        holder: CoreHolder, watched: Bool, refillPace: RefillPace = .standard, clock: RefillClock = .continuous,
        instanceAt: @escaping InstanceAt = instanceAt
    ) {
        self.clock = clock
        self.holder = holder
        self.watched = watched
        self.refillPace = refillPace
        self.instanceAt = instanceAt
    }

    /// Runs `body` under the lock, then tells what it queued to stream
    /// continuations, outside the lock.
    private func locked<T: Sendable>(_ body: (inout State) throws -> T) rethrows -> T {
        let (result, told) = try state.withLock { state -> (T, [(AsyncStream<Change>.Continuation, Change?)]) in
            let result = try body(&state)
            return (result, state.told.drain())
        }
        // Finishing a stream runs its termination handler, which takes the lock.
        for (continuation, change) in told {
            if let change { continuation.yield(change) } else { continuation.finish() }
        }
        return result
    }

    var count: Int { locked { $0.streams.count } }

    /// Whether the feed was closed, which it is before any of its streams finish.
    var isClosed: Bool { locked { $0.closed } }

    func add(_ continuation: AsyncStream<Change>.Continuation, as token: UUID = UUID()) -> UUID? {
        let (added, joins) = locked { state -> (Bool, Bool) in
            guard !state.closed else { return (false, false) }
            let suspended = state.suspends > 0
            state.streams[token] = Stream(continuation: continuation, addedWhileSuspended: suspended)
            return (true, !suspended)
        }
        guard added else {
            continuation.finish()
            return nil
        }
        if joins { join(token) }
        return token
    }

    func remove(_ token: UUID) {
        let subscription = locked { state in state.streams.removeValue(forKey: token)?.subscription }
        subscription?.stop()
    }

    func announce(_ write: QueuedWrite) {
        announce(Change(origin: .local(write.kind), itemId: write.itemId, edgeId: write.edgeId))
    }

    func announce(_ change: Change) {
        for continuation in locked({ $0.streams.values.map(\.continuation) }) {
            continuation.yield(change)
        }
    }

    /// Ends every stream, takes each out of the watch, and returns once the core
    /// has let go of all of them, and so of the store.
    func close() async {
        let (streams, waiters) = locked { state -> ([Stream], [CheckedContinuation<Void, any Error>]) in
            state.closed = true
            state.refill.task?.cancel()
            defer {
                state.streams = [:]
                state.fillWaiters = []
            }
            return (Array(state.streams.values), state.fillWaiters.map(\.continuation))
        }
        for waiter in waiters { waiter.resume(throwing: MarfaError.closed(message: CoreHolder.closedMessage)) }
        // Finishing a stream runs its termination handler, which takes the lock.
        for stream in streams { stream.continuation.finish() }
        for stream in streams { stream.subscription?.stop() }
        await untilLetGo()
    }

    /// Takes every stream out of the watch until `resume(readsOnly:)`, and
    /// returns once the core has let go of the store.
    ///
    /// The streams stay held. Throws `closed` once the feed is.
    func suspend() async throws {
        let leaving = try locked { state -> [MarfaCore.Subscription] in
            guard !state.closed else { throw MarfaError.closed(message: CoreHolder.closedMessage) }
            state.suspends += 1
            state.suspensions += 1
            // A new key may read under another reach than the one the server last answered for.
            state.refill.vouched = false
            var leaving: [MarfaCore.Subscription] = []
            for token in state.streams.keys {
                if let subscription = state.streams[token]?.subscription { leaving.append(subscription) }
                state.streams[token]?.subscription = nil
                state.streams[token]?.registration = nil
            }
            return leaving
        }
        for subscription in leaving { subscription.stop() }
        await untilLetGo()
    }

    /// Gives every stream a place in the new core's watch, told what it was
    /// last told of the server.
    ///
    /// A reader's stream added meanwhile could take no baseline, and a save
    /// since may have gone unseen, so each is told one `.saved` to read again.
    func resume(readsOnly: Bool) {
        let (joining, late) = locked { state -> ([UUID], [UUID]) in
            state.suspends -= 1
            guard state.suspends == 0, !state.closed else { return ([], []) }
            let late = state.streams.filter { $0.value.addedWhileSuspended }.map(\.key)
            for token in late { state.streams[token]?.addedWhileSuspended = false }
            return (Array(state.streams.keys), late)
        }
        for token in joining { join(token) }
        guard readsOnly, !late.isEmpty, let now = try? holder.with({ try $0.dataVersion() }) else { return }
        let saved = Change(origin: .saved(dataVersion: now), itemId: nil, edgeId: nil)
        locked { state in
            for token in late {
                if let stream = state.streams[token] { state.told.append((stream.continuation, saved)) }
            }
        }
    }

    /// Takes a place in the core's watch for one stream, with no lock held across the
    /// call that reads a reader's baseline, which can wait on the store.
    private func join(_ token: UUID) {
        guard watched else { return }
        let claim = locked { state -> (registration: Int, unreachable: Bool)? in
            guard !state.closed, state.suspends == 0, var stream = state.streams[token],
                stream.registration == nil
            else { return nil }
            state.registrations += 1
            stream.registration = state.registrations
            state.streams[token] = stream
            state.open.insert(state.registrations)
            return (state.registrations, stream.unreachable)
        }
        guard let claim else { return }
        let listener = Listener(feed: self, token: token, registration: claim.registration)
        let joined = Result {
            try holder.with { try $0.watch(toldUnreachable: claim.unreachable, listener: listener) }
        }
        switch joined {
        case .success(let subscription):
            // A stream let go, or a core replaced or closed, while the call ran has
            // no use for the place; it ends on its own.
            let unwanted = locked { state -> Bool in
                if state.closed || state.suspends > 0 || state.streams[token]?.registration != claim.registration {
                    return true
                }
                state.streams[token]?.subscription = subscription
                return false
            }
            if unwanted { subscription.stop() }
        case .failure(let error):
            let waiters = locked { state -> [CheckedContinuation<Void, Never>] in
                if state.streams[token]?.registration == claim.registration {
                    end(&state, token, with: error as? MarfaError ?? .store(message: "\(error)"))
                }
                return release(&state, claim.registration)
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    /// What the core's thread tells a stream: dropped unless it comes from the
    /// stream's current place in the watch.
    fileprivate func heard(_ change: MarfaCore.Change, by token: UUID, registration: Int) {
        let refills = locked { state -> Bool in
            guard var stream = state.streams[token], stream.registration == registration else { return false }
            switch change {
            case .serverUnreachable: stream.unreachable = true
            case .serverReachable: stream.unreachable = false
            case .watchFailed(let reason, _):
                // An aged-out cursor expires the copy as well, so which it was is read from the store.
                if case .copyExpired(let why, _) = MarfaError(reason) {
                    state.refill.waiting.insert(token)
                    state.refill.reason = MarfaError(reason)
                    // The core refuses a copy that was stale already with this reason, asking the server nothing.
                    if why != "catchup_too_old" { state.refill.vouched = true }
                    guard !state.refill.running else { return false }
                    state.refill.running = true
                    if let filledAt = state.refill.filledAt, clock.now - filledAt >= refillPace.settle {
                        state.refill.attempts = 0
                    }
                    return true
                }
            default: break
            }
            state.streams[token] = stream
            for told in Self.translated(change) { state.told.append((stream.continuation, told)) }
            return false
        }
        guard refills else { return }
        let task = Task { [weak self] in _ = await self?.refill() }
        locked { state in
            if state.closed { task.cancel() } else if state.refill.running { state.refill.task = task }
        }
    }

    /// Runs the app's hydration, after any other hydration or catch-up this copy is running, and tells every stream
    /// how it ended.
    ///
    /// One that waited, for the same slice as a hydration that just completed under the same key, returns that one's
    /// report while the copy is still whole.
    func hydrate(types: [String], tier: MarfaCore.SliceTier, edgeTypes: [String]) async throws
        -> MarfaCore.HydrateReport
    {
        let waited = try await takeFill()
        defer { releaseFill() }
        let underThisKey = { (state: inout State) in
            state.lastFill.flatMap { $0.suspensions == state.suspensions ? $0 : nil }
        }
        if waited, let filled = locked(underThisKey),
            filled.types == types, filled.tier == tier, filled.edgeTypes == edgeTypes,
            (try? await holder.run({ try $0.status() }).hydration) == .complete
        {
            return filled.report
        }
        return try await fill(types: types, tier: tier, edgeTypes: edgeTypes, byRefill: false)
    }

    /// Runs the app's catch-up after any hydration or catch-up this copy is running, since the core refuses one
    /// that meets another.
    func catchUp<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        _ = try await takeFill()
        defer { releaseFill() }
        locked { $0.lastFill = nil }
        return try await work()
    }

    /// Waits until no other hydration or catch-up of this copy runs, and says whether it had to.
    private func takeFill() async throws -> Bool {
        let id = UUID()
        var waited = false
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let now = locked { state -> Result<Void, any Error>? in
                    if state.closed { return .failure(MarfaError.closed(message: CoreHolder.closedMessage)) }
                    if Task.isCancelled { return .failure(MarfaError.canceled(message: "the call was canceled")) }
                    guard state.filling else {
                        state.filling = true
                        return .success(())
                    }
                    state.fillWaiters.append((id, continuation))
                    return nil
                }
                if let now { continuation.resume(with: now) } else { waited = true }
            }
        } onCancel: {
            let waiter = locked { state -> CheckedContinuation<Void, any Error>? in
                guard let index = state.fillWaiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.fillWaiters.remove(at: index).continuation
            }
            waiter?.resume(throwing: MarfaError.canceled(message: "the call was canceled"))
        }
        return waited
    }

    /// Hands the turn to the next waiting hydration or catch-up.
    private func releaseFill() {
        let next = locked { state -> CheckedContinuation<Void, any Error>? in
            guard !state.fillWaiters.isEmpty else {
                state.filling = false
                return nil
            }
            return state.fillWaiters.removeFirst().continuation
        }
        next?.resume()
    }

    /// Runs a hydration, holding the turn `takeFill` gave, and tells every stream how it ended.
    ///
    /// `admitted` is asked under the core's lease, which a key change waits for, so the fill runs under the key it
    /// approved; where it answers `false` the fill throws `KeyChanged` and tells nothing.
    private func fill(
        types: [String], tier: MarfaCore.SliceTier, edgeTypes: [String], byRefill: Bool,
        admitted: @escaping @Sendable () -> Bool = { true }
    ) async throws -> MarfaCore.HydrateReport {
        let suspensions = locked { state in
            state.lastFill = nil
            if !byRefill { state.refill.unfinished = false }
            return state.suspensions
        }
        let report: MarfaCore.HydrateReport
        do {
            report = try await holder.runUntilCanceled { core, stop in
                guard admitted() else { throw KeyChanged() }
                return try core.hydrateWith(types: types, tier: tier, edgeTypes: edgeTypes, stop: stop)
            }
        } catch let error as KeyChanged {
            throw error
        } catch  where !admitted() {
            // A key change reopening the store refuses the lease before `admitted` is asked.
            throw KeyChanged()
        } catch {
            announce(Change(origin: .refreshed(.unfinished), itemId: nil, edgeId: nil))
            throw error
        }
        locked {
            $0.lastFill = Fill(
                types: types, tier: tier, edgeTypes: edgeTypes, report: report, suspensions: suspensions)
        }
        announce(Change(origin: .refreshed(.hydrated), itemId: nil, edgeId: nil))
        return report
    }

    /// Fills a stale copy again over the slice it holds, so the follow the core halted starts again.
    ///
    /// A failure the network or the server may mend is tried again, further apart each time; any other is told to
    /// the streams waiting on it as `.stopped`, as the follow's own failure would have been.
    private func refill() async {
        while true {
            let next = locked { state -> (delay: Duration, owed: Set<UUID>)? in
                state.refill.waiting = state.refill.waiting.filter { state.streams[$0] != nil }
                guard !state.closed, !state.refill.waiting.isEmpty else {
                    state.refill = Refill(attempts: state.refill.attempts, filledAt: state.refill.filledAt)
                    return nil
                }
                let attempts = state.refill.attempts
                state.refill.attempts += 1
                let backoff =
                    attempts == 0 ? .zero : min(refillPace.first * (1 << min(attempts - 1, 30)), refillPace.most)
                let delay = max(backoff, min(state.refill.retryAfter, refillPace.most))
                state.refill.retryAfter = .zero
                let owed = state.refill.waiting
                state.refill.waiting = []
                return (delay, owed)
            }
            guard let next else { return }
            if next.delay > .zero { try? await clock.sleep(for: next.delay) }
            let failure: MarfaError?
            do {
                _ = try await takeFill()
                defer { releaseFill() }
                failure = try await refillOnce()
            } catch let error as MarfaError where Self.mendsItself(error) {
                locked { state in
                    state.refill.waiting.formUnion(next.owed)
                    if case .rateLimited(_, _, let seconds?) = error { state.refill.retryAfter = .seconds(seconds) }
                }
                continue
            } catch {
                failure = error as? MarfaError ?? .store(message: "\(error)")
            }
            guard let failure else { continue }
            locked { state in
                for token in next.owed.union(state.refill.waiting) {
                    if let stream = state.streams[token] {
                        state.told.append((stream.continuation, Self.stopped(failure)))
                    }
                }
                state.refill = Refill(filledAt: state.refill.filledAt)
            }
            return
        }
    }

    /// One attempt, holding the hydration turn: `nil` where the copy is whole or filling, or was filled, and
    /// otherwise the stop to tell.
    private func refillOnce() async throws -> MarfaError? {
        let suspensions = locked { $0.suspensions }
        let status = try await holder.run { try $0.status() }
        let reason = locked { $0.refill.reason } ?? .copyExpired(reason: "catchup_too_old", message: "")
        switch status.hydration {
        // The app's hydration, or an earlier refill, mended it; a later aged-out cursor halts the follow again.
        case .complete:
            return nil
        // A fill the app began and did not finish is its own to carry on, and the core's follow waits for it.
        case .inProgress where !locked({ $0.refill.unfinished }):
            return nil
        case .stale, .inProgress:
            guard let tier = status.sliceTier, locked({ $0.refill.vouched }) else { return reason }
            guard let origin = status.serverOrigin, let built = status.instanceId else { return reason }
            // The core fills a copy built under another instance from scratch instead of in place, and a queued
            // write would then be sent to that instance.
            guard try await instanceAt(origin) == built else {
                return .copyExpired(
                    reason: "instance_changed",
                    message: "another instance answers at the copy's server; hydrate to replace the copy")
            }
            do {
                // A key changed since this attempt began may read under another reach than the one vouched for.
                _ = try await fill(
                    types: status.sliceTypes, tier: tier, edgeTypes: status.sliceEdgeTypes, byRefill: true,
                    admitted: { [self] in
                        locked { $0.suspensions == suspensions && $0.refill.vouched }
                    })
            } catch is KeyChanged {
                return reason
            } catch let error as MarfaError where Self.mendsItself(error) {
                locked { $0.refill.unfinished = true }
                throw error
            }
            locked { state in
                state.refill.filledAt = clock.now
                state.refill.unfinished = false
            }
            return nil
        default:
            return reason
        }
    }

    /// The failures the core's own follow waits out, `CoreError::is_environmental`.
    private static func mendsItself(_ error: MarfaError) -> Bool {
        switch error {
        case .network, .io, .storageFull, .rateLimited, .unnamed: true
        case .server(let status, _, _): status >= 500 || status == 408
        default: false
        }
    }

    /// Resumes waiters only once nothing on this thread holds the feed, since one may
    /// drop the working copy and open the store again at once.
    fileprivate func letGo(by token: UUID, registration: Int, error: MarfaError?) {
        let waiters = locked { state -> [CheckedContinuation<Void, Never>] in
            if state.streams[token]?.registration == registration {
                if let error {
                    end(&state, token, with: error)
                } else {
                    state.streams[token]?.registration = nil
                    state.streams[token]?.subscription = nil
                }
            }
            return release(&state, registration)
        }
        for waiter in waiters { waiter.resume() }
    }

    /// A stream whose place the core ended on a fault, or refused, is told why and
    /// ends: a recovery or a key change must not take a place for it again, and the
    /// app needs to tell it from a watch failure, which a recovery restarts.
    private func end(_ state: inout State, _ token: UUID, with error: MarfaError) {
        guard let stream = state.streams.removeValue(forKey: token) else { return }
        state.told.append((stream.continuation, Self.stopped(error)))
        state.told.append((stream.continuation, nil))
    }

    private func release(_ state: inout State, _ registration: Int) -> [CheckedContinuation<Void, Never>] {
        state.open.remove(registration)
        guard state.open.isEmpty else { return [] }
        return state.waitingForEnd.drain()
    }

    private func untilLetGo() async {
        await withCheckedContinuation { continuation in
            let done = locked { state -> Bool in
                guard !state.open.isEmpty else { return true }
                state.waitingForEnd.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    private static func stopped(_ error: MarfaError) -> Change {
        Change(origin: .stopped(error), itemId: nil, edgeId: nil)
    }

    private static func translated(_ change: MarfaCore.Change) -> [Change] {
        switch change {
        case .applied(let event, let itemId, let edgeId, let cursor):
            return [Change(origin: .server(event: event, cursor: cursor), itemId: itemId, edgeId: edgeId)]
        case .catalogChanged:
            return [Change(origin: .refreshed(.catalog), itemId: nil, edgeId: nil)]
        case .serverUnreachable(let reason, _):
            return [Change(origin: .serverUnreachable(MarfaError(reason)), itemId: nil, edgeId: nil)]
        case .serverReachable:
            return [Change(origin: .serverReachable, itemId: nil, edgeId: nil)]
        case .queueDrained(let report, _):
            let report = DrainReport(report)
            return report.changes() + [Change(origin: .queueDrained(report), itemId: nil, edgeId: nil)]
        case .queueNotDrained(let error, _):
            return [Change(origin: .queueNotDrained(MarfaError(error)), itemId: nil, edgeId: nil)]
        case .saved(let dataVersion, _):
            return [Change(origin: .saved(dataVersion: dataVersion), itemId: nil, edgeId: nil)]
        case .watchFailed(let reason, _):
            return [stopped(MarfaError(reason))]
        }
    }
}

/// One stream's place in the core's watch.
///
/// Weak on the feed, which holds the core holder and with it the writer's claim
/// on the store: the core holds the listener until `ended` returns.
final class Listener: MarfaCore.ChangeListener, Sendable {
    private struct Weak {
        weak var feed: Feed?
    }

    private let held: Mutex<Weak>
    private let token: UUID
    private let registration: Int

    init(feed: Feed, token: UUID, registration: Int) {
        held = Mutex(Weak(feed: feed))
        self.token = token
        self.registration = registration
    }

    private var feed: Feed? { held.withLock { $0.feed } }

    func changed(change: MarfaCore.Change) {
        feed?.heard(change, by: token, registration: registration)
    }

    func ended(error: MarfaCore.MarfaError?) {
        feed?.letGo(by: token, registration: registration, error: error.map(MarfaError.init))
    }
}
