import Foundation
import MarfaCore
import Synchronization

/// The streams `changes()` hands out.
///
/// Each stream is its own listener in the core's watch, which holds the one
/// source, tells every listener what the server did, and keeps a hydration or
/// catch-up from meeting a follow. The feed adds what the core cannot know: the
/// app's own announcements, the end of every stream when the copy closes, and
/// a new place in the watch for each stream when the core is replaced.
final class Feed: Sendable {
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
        var registrations = 0
        /// Places the core has not yet let go; the store is free when none is left.
        var open: Set<Int> = []
        var waitingForEnd: [CheckedContinuation<Void, Never>] = []
        /// Told once the lock is let go; `nil` ends the stream.
        var told: [(AsyncStream<Change>.Continuation, Change?)] = []
    }

    let holder: CoreHolder
    /// Whether the core has a watch to give: a writer with a server, or a reader.
    private let watched: Bool
    private let state = Mutex(State())

    init(holder: CoreHolder, watched: Bool) {
        self.holder = holder
        self.watched = watched
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
        let streams = locked { state -> [Stream] in
            state.closed = true
            defer { state.streams = [:] }
            return Array(state.streams.values)
        }
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
        locked { state in
            guard var stream = state.streams[token], stream.registration == registration else { return }
            switch change {
            case .serverUnreachable: stream.unreachable = true
            case .serverReachable: stream.unreachable = false
            default: break
            }
            state.streams[token] = stream
            for told in Self.translated(change) { state.told.append((stream.continuation, told)) }
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
