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
///     for await state in manager.stateUpdates {
///         print("connection: \(state)")
///     }
public actor ConnectionStateManager {

    // MARK: - State

    public private(set) var state: ConnectionState = .offline

    // MARK: - Broadcast subscribers

    private var continuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    // MARK: - NWPathMonitor plumbing

    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "myme.sdk.path_monitor", qos: .utility)
    private var started = false

    // MARK: - Init

    public init() {
        monitor = NWPathMonitor()
    }

    // MARK: - Lifecycle

    /// Starts monitoring. Idempotent — calling again while already started is a no-op.
    public func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            // Bridge from DispatchQueue into the actor.
            Task { [weak self] in
                await self?.handlePath(path)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    /// Stops monitoring and terminates all open ``stateUpdates`` streams.
    public func stop() {
        monitor.cancel()
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
    public var stateUpdates: AsyncStream<ConnectionState> {
        let current = state
        return AsyncStream { continuation in
            let id = UUID()
            // Register before yielding so onTermination can never fire for
            // an id that isn't yet in the dictionary.
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeContinuation(id: id)
                }
            }
            // Deliver the current state to the new subscriber immediately.
            continuation.yield(current)
        }
    }

    // MARK: - Private

    private func handlePath(_ path: NWPath) {
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
    /// `@testable import MymeSDK` tests can call it; no public API.
    internal func applyStateForTesting(_ state: ConnectionState) {
        applyState(state)
    }
}
