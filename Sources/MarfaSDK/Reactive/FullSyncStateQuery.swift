import Foundation
import Observation

/// A live, observable projection of the engine's
/// ``FullSyncState``.
///
/// Folds two signals into a single discrete state:
///
/// 1. The persisted `last_clean_drain_at` timestamp on init — sets the
///    starting state to ``FullSyncState/synced(at:)`` when present, or
///    ``FullSyncState/notYetSynced`` when absent.
/// 2. ``SyncEngine/events`` — ``SyncEvent/syncing`` lands as
///    ``FullSyncState/syncing``, ``SyncEvent/synced(at:)`` as
///    ``FullSyncState/synced(at:)`` (clearing any prior failure), and
///    ``SyncEvent/failed(error:)`` as
///    ``FullSyncState/failed(at:error:)``.
///
/// Subscribing to a single event stream — rather than to
/// ``SyncEngine/events`` plus ``ConnectionStateManager/stateUpdates`` —
/// keeps event ordering deterministic. Two-stream folds raced when
/// `markSyncing` fired on the connection-manager and `recordCleanDrain`
/// emitted `.synced` on the engine, because the @MainActor consumer
/// would receive them in arbitrary order and a stale `.syncing` could
/// overwrite a fresh `.synced`.
///
/// ## Usage
///
///     if let query = store.queryFullSyncState() {
///         switch query.state {
///         case .notYetSynced: ProgressView("First sync…")
///         case .syncing:      ProgressView("Syncing…")
///         case .synced(let at): Text("Last synced \(at, format: .relative(presentation: .named))")
///         case .failed(_, let error): Text("Couldn't sync: \(error.localizedDescription)")
///         }
///     }
///
/// Vended by ``MarfaStore/queryFullSyncState()``. Returns `nil` for
/// network-only or pure-local clients without a sync engine — those
/// shapes have no meaningful sync state to render against.
@Observable
@MainActor
public final class FullSyncStateQuery {

    // MARK: - Published state

    /// Current ``FullSyncState``. Updates on the main actor whenever
    /// engine events arrive.
    public private(set) var state: FullSyncState = .notYetSynced

    // MARK: - Internals

    private var eventListenerTask: Task<Void, Never>?
    private var initialLoadTask: Task<Void, Never>?

    // MARK: - Init

    init(engine: SyncEngine) {
        let events = engine.events

        // Seed the initial state from the persisted timestamp. The
        // listener task below runs concurrently; if a `.synced` /
        // `.syncing` / `.failed` event lands before the seed
        // completes the event takes precedence (it's fresher), so
        // the race is benign.
        self.initialLoadTask = Task { @MainActor [weak self] in
            let stamped = await engine.lastCleanDrainAt
            guard !Task.isCancelled, let self else { return }
            // Only seed if we haven't already moved off `.notYetSynced`
            // — a concurrent event-listener update would otherwise be
            // overwritten by stale persisted state.
            if case .notYetSynced = self.state, let stamped {
                self.state = .synced(at: stamped)
            }
        }

        self.eventListenerTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                self.apply(event)
            }
        }
    }

    private func apply(_ event: SyncEvent) {
        switch event {
        case .syncing:
            state = .syncing
        case let .synced(at):
            state = .synced(at: at)
        case let .failed(error):
            state = .failed(at: Date(), error: error)
        default:
            // Other events (item.*, edge.*, blob.*, conflict, dropped)
            // don't move the full-sync state machine — they're either
            // SSE-applied changes (the cycle isn't terminal yet) or
            // per-record signals that fold under the cycle's outcome
            // via `synced` / `failed` above.
            break
        }
    }

    // MARK: - Lifecycle

    /// Stops the listener task and the initial-load task. After
    /// calling `stop()`, ``state`` will no longer update.
    public func stop() {
        eventListenerTask?.cancel()
        eventListenerTask = nil
        initialLoadTask?.cancel()
        initialLoadTask = nil
    }
}
