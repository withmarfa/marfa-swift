import Foundation

/// Discrete state covering the engine's "is everything caught up?" axis.
///
/// Composes two underlying signals into a single value apps can render
/// against without writing their own reducer:
///
/// 1. The mutation queue's drain progress (`SyncEngine.replayMutations`).
/// 2. The most recent drain's outcome (`SyncEvent.synced` / `SyncEvent.failed`).
///
/// "Caught up" here means a clean drain cycle finished — both the SSE
/// event application and the queued-mutation replay completed without an
/// outstanding error. SSE itself is open-ended (the server can push at
/// any moment), so the state collapses both axes onto the engine's
/// per-cycle outcome rather than trying to assert "no events pending".
///
/// Read it via ``SyncEngine/fullSyncState`` for a point-in-time value, or
/// subscribe via ``MymeStore/queryFullSyncState()`` for a reactive
/// `@Observable` view bound to the local store.
///
/// Not `Equatable` — the ``failed(at:error:)`` case carries an `Error`
/// which doesn't synthesise. SwiftUI animation can drive off the case
/// discriminator (e.g. `state.caseId`) when comparison is needed.
public enum FullSyncState: Sendable {
    /// Engine has not completed a clean drain cycle since this local
    /// store was opened, and no prior session left a persisted
    /// completion timestamp. Cold-start state — apps render a "waiting
    /// for first sync" affordance.
    case notYetSynced

    /// Engine is mid-cycle: receiving SSE events, replaying queued
    /// mutations, or both. Apps render a spinner / "Syncing…" affordance.
    case syncing

    /// Engine completed a clean drain cycle. Carries the timestamp of
    /// the most recent completion. Persisted as `last_clean_drain_at`
    /// in the `sync_state` table — survives app restarts.
    case synced(at: Date)

    /// The most recent cycle bailed with an error. Replaced by
    /// ``syncing`` on the next attempt; replaced by ``synced(at:)`` on
    /// the next clean completion. Not persisted: a cold start
    /// mid-failure returns to ``notYetSynced`` (or ``synced(at:)`` if a
    /// prior clean drain stamped the store).
    case failed(at: Date, error: Error)
}
