import Foundation
import Network

/// Tracks network reachability and translates it into a ``ConnectionState``
/// stream that the ``SyncEngine`` observes.
///
/// `NWPathMonitor` runs on its own `DispatchQueue`; updates are bridged into
/// the actor via a `Task`-based hop to preserve Swift 6 actor isolation.
///
/// ## Usage
///
///     let manager = ConnectionStateManager()
///     let updates = await manager.stateUpdates
///     for await state in updates {
///         print("connection: \(state)")
///     }
public actor ConnectionStateManager {

    // MARK: - State

    public private(set) var state: ConnectionState = .offline

    // MARK: - Broadcast subscribers

    private var continuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

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
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
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
    /// Actor isolation makes registration synchronous with property access:
    /// once the caller receives the stream, an immediate ``stop()`` cannot
    /// overtake a detached subscription task and leave the stream unfinished.
    public var stateUpdates: AsyncStream<ConnectionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ConnectionState>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeContinuation(id: id)
            }
        }
        continuations[id] = continuation
        continuation.yield(state)
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
        guard next != state else { return }
        state = next
        for continuation in continuations.values {
            continuation.yield(next)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
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

    internal var markOnlineCallCountForTesting: Int {
        markOnlineCallCount
    }
}
