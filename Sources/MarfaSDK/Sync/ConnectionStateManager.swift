import Foundation
import Network
import Synchronization

/// Tracks network reachability and translates it into a ``ConnectionState``
/// stream that the ``SyncEngine`` observes.
///
/// `NWPathMonitor` runs on its own `DispatchQueue`; updates are bridged into
/// the actor via a `Task`-based hop to preserve Swift 6 actor isolation.
///
/// ## Usage
///
///     let manager = ConnectionStateManager()
///     for await state in manager.stateUpdates {
///         print("connection: \(state)")
///     }
public actor ConnectionStateManager {

    // MARK: - Broadcast state

    /// Current state and open subscribers, held under a mutex rather than in
    /// actor storage so that subscribing is synchronous with the
    /// ``stateUpdates`` access that hands the stream back. Registering through
    /// a detached task instead would let a ``stop()`` issued on the next line
    /// run first, leaving the new continuation attached to a stopped manager
    /// and its consumer awaiting a state that can never arrive. `state` lives
    /// alongside the subscribers because a new stream is handed the current
    /// value at the instant it registers, and reading it through a separate
    /// mechanism would reintroduce the gap between the two.
    private struct Broadcast {
        var state: ConnectionState = .offline
        var continuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    }

    private let broadcast = Mutex(Broadcast())

    // MARK: - State

    public nonisolated var state: ConnectionState {
        broadcast.withLock { $0.state }
    }

    // MARK: - NWPathMonitor plumbing

    private var monitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "marfa.sdk.path_monitor", qos: .utility)
    private var started = false
    private var monitoringGeneration: UUID?

    /// Counts ``markOnline()`` calls. `markOnline` is a no-op once the manager
    /// is offline, so a caller that transitions after shutdown leaves no trace
    /// in the state machine; the counter makes that call observable to tests.
    private var markOnlineCallCount = 0

    // MARK: - Init

    public init() {}

    // MARK: - Lifecycle

    /// Starts monitoring. Idempotent — calling again while already started is a no-op.
    public func start() {
        guard !started else { return }
        let monitor = NWPathMonitor()
        let generation = UUID()
        self.monitor = monitor
        started = true
        monitoringGeneration = generation
        monitor.pathUpdateHandler = { [weak self] path in
            // Bridge from DispatchQueue into the actor.
            Task { [weak self] in
                await self?.handlePath(path, generation: generation)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    /// Stops monitoring and terminates all open ``stateUpdates`` streams.
    public func stop() {
        started = false
        monitoringGeneration = nil
        monitor?.cancel()
        monitor = nil
        applyState(.offline)
        // Take the subscribers out of the lock before finishing them.
        // `finish()` can run a continuation's termination handler inline, and
        // that handler reaches back for this same lock to deregister.
        let open = broadcast.withLock { broadcast -> [AsyncStream<ConnectionState>.Continuation] in
            defer { broadcast.continuations.removeAll() }
            return Array(broadcast.continuations.values)
        }
        for continuation in open {
            continuation.finish()
        }
    }

    // MARK: - Manual transitions

    /// Called by the ``SyncEngine`` to signal ongoing server activity.
    public func markSyncing() {
        guard state != .offline else { return }
        applyState(.syncing)
    }

    /// Called by the ``SyncEngine`` when the SSE stream is idle.
    public func markOnline() {
        markOnlineCallCount += 1
        guard state != .offline else { return }
        applyState(.online)
    }

    /// Called by the ``SyncEngine`` to nudge the state machine back into
    /// `.connecting` after an SSE stream closes. `NWPathMonitor` only
    /// emits transitions on real network flaps, so without this the engine
    /// would drain the mutation queue once per network event and then park
    /// on `.online` forever — new mutations would sit unsynced until the
    /// next reachability change. Guarded against calling while offline so
    /// we never claim "connecting" when the network is actually down;
    /// `NWPathMonitor`'s own offline → connecting transition handles
    /// resume from loss.
    public func markConnecting() {
        guard state != .offline else { return }
        applyState(.connecting)
    }

    // MARK: - AsyncStream factory

    /// An `AsyncStream` that yields the current state immediately, then any
    /// subsequent state changes. The stream ends when ``stop()`` is called.
    ///
    /// Registration completes before the property returns, so a caller that
    /// takes a stream and immediately calls ``stop()`` gets a finished stream
    /// rather than one that never yields and never ends. `nonisolated` keeps
    /// subscribing free of an actor hop; the mutex, not the actor, is what
    /// makes it atomic.
    public nonisolated var stateUpdates: AsyncStream<ConnectionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ConnectionState>.makeStream()
        continuation.onTermination = { [weak self] _ in
            self?.removeContinuation(id: id)
        }
        let current = broadcast.withLock { broadcast -> ConnectionState in
            broadcast.continuations[id] = continuation
            return broadcast.state
        }
        continuation.yield(current)
        return stream
    }

    // MARK: - Private

    private func handlePath(_ path: NWPath, generation: UUID) {
        // A cancelled monitor may already have queued an update. Ignore it so
        // stop() remains terminal for that monitoring lifecycle, even if a
        // later start() has installed a replacement monitor.
        guard started, monitoringGeneration == generation else { return }
        let next: ConnectionState = path.status == .satisfied ? .connecting : .offline
        applyState(next)
    }

    private func applyState(_ next: ConnectionState) {
        // Yield outside the lock for the same reason `stop()` does: a
        // terminated stream runs its handler inline, and that handler
        // deregisters through this lock.
        let subscribers = broadcast.withLock { broadcast -> [AsyncStream<ConnectionState>.Continuation] in
            guard next != broadcast.state else { return [] }
            broadcast.state = next
            return Array(broadcast.continuations.values)
        }
        for continuation in subscribers {
            continuation.yield(next)
        }
    }

    private nonisolated func removeContinuation(id: UUID) {
        broadcast.withLock { $0.continuations.removeValue(forKey: id) }
    }

    // MARK: - Test seam

    /// Drives a state transition without going through `NWPathMonitor`.
    /// Intended for unit tests — `NWPathMonitor` is hard to simulate and
    /// varies per host — and for host apps that want to override reachability
    /// (e.g. "airplane mode" toggles in dev builds). Marked `internal` so
    /// `@testable import MarfaSDK` tests can call it; no public API.
    internal func applyStateForTesting(_ state: ConnectionState) {
        applyState(state)
    }

    internal var isStartedForTesting: Bool {
        started
    }

    internal nonisolated var subscriberCountForTesting: Int {
        broadcast.withLock { $0.continuations.count }
    }

    internal var markOnlineCallCountForTesting: Int {
        markOnlineCallCount
    }
}
