import Foundation
import Observation

/// A live, observable projection of the engine's
/// ``FullSyncState``.
///
/// Folds two signals into a single discrete state:
///
/// 1. The engine's own ``SyncEngine/fullSyncState`` on init — which reads the
///    persisted `last_clean_drain_at` timestamp *and* whether the queue is
///    parked, so a store opened over a refused credential does not start on
///    the timestamp a healthy session left behind. Sets the starting state, or
///    ``FullSyncState/notYetSynced`` when absent.
/// 2. ``SyncEngine/events`` — ``SyncEvent/syncing`` lands as
///    ``FullSyncState/syncing``, ``SyncEvent/synced(at:)`` as
///    ``FullSyncState/synced(at:)`` (clearing any prior failure),
///    ``SyncEvent/failed(error:)`` as ``FullSyncState/failed(at:error:)``,
///    and ``SyncEvent/queueParked(reason:count:)`` as
///    ``FullSyncState/parked(reason:count:)``.
///
/// **This is a latched fold, which is why the engine makes the park a
/// cycle's terminal event.** `queueParked` on its own answers "this just
/// happened" rather than "is this still true", so a later cycle that failed
/// would otherwise overwrite a standing park with nothing to put it back.
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
///         case .parked(_, let count): Text("Sign in again — \(count) unsent")
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

        // Seed the initial state from the engine, which reads the park as well
        // as the persisted timestamp. The listener task below runs
        // concurrently; if a `.synced` / `.syncing` / `.failed` /
        // `.queueParked` event lands before the seed completes the event takes
        // precedence (it's fresher), so the race is benign.
        //
        // **Through `fullSyncState` rather than the timestamp alone**, because
        // a store that synced cleanly before its credential was refused still
        // holds that stamp — so seeding from it directly opens an app on "last
        // synced an hour ago" over a queue that has stopped, and nothing
        // afterwards corrects it until an event happens to arrive.
        self.initialLoadTask = Task { @MainActor [weak self] in
            let seeded = await engine.fullSyncState
            guard !Task.isCancelled, let self else { return }
            // Only seed if we haven't already moved off `.notYetSynced`
            // — a concurrent event-listener update would otherwise be
            // overwritten by stale persisted state.
            if case .notYetSynced = self.state, case .notYetSynced = seeded {
                return
            }
            if case .notYetSynced = self.state {
                self.state = seeded
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
        case let .queueParked(reason, count):
            // **Without this the shipped SwiftUI surface never moves.** This
            // query is event-driven after its initial load, so a view already
            // sitting at `.synced` from a healthy session goes on rendering
            // "last synced" over a queue that has stopped — the engine's own
            // `fullSyncState` reads the park, and nothing was telling this.
            state = .parked(reason: reason, count: count)
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
