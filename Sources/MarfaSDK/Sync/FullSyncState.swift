import Foundation

/// Discrete state covering the engine's "is everything caught up?" axis.
///
/// Composes three underlying signals into a single value apps can render
/// against without writing their own reducer:
///
/// 1. The mutation queue's drain progress (`SyncEngine.replayMutations`).
/// 2. The most recent drain's outcome (`SyncEvent.synced` / `SyncEvent.failed`).
/// 3. Whether the queue has stopped on a refused credential, which outranks
///    both of the above — see ``parked(reason:count:)``.
///
/// "Caught up" here means a clean drain cycle finished — both the SSE
/// event application and the queued-mutation replay completed without an
/// outstanding error. SSE itself is open-ended (the server can push at
/// any moment), so the state collapses both axes onto the engine's
/// per-cycle outcome rather than trying to assert "no events pending".
///
/// Read it via ``SyncEngine/fullSyncState`` for a point-in-time value, or
/// subscribe via ``MarfaStore/queryFullSyncState()`` for a reactive
/// `@Observable` view bound to the local store.
///
/// Not `Equatable` — the ``failed(at:error:)`` case carries an `Error`
/// which doesn't synthesize. Where comparison is needed, match on the case
/// with `if case` or a `switch` rather than on the value. **An earlier
/// version of this paragraph suggested `state.caseId`, which has never
/// existed in this package**; anyone who tried it got a build error rather
/// than a wrong answer, but it is worth not sending the next reader after
/// something that is not there.
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

    /// Every unsent write has stopped together, for a reason no retry can
    /// clear. Today that means a credential the server refused and the
    /// transport could not refresh.
    ///
    /// **It outranks both ``synced(at:)`` and ``failed(at:error:)``, and each
    /// for its own reason.** A store that synced cleanly an hour ago still
    /// holds that timestamp, and nothing about a refused credential erases it,
    /// so without this the app renders "Last synced an hour ago" over a queue
    /// that has stopped — the answer is true and it is not the answer to the
    /// question being asked. A transient failure recorded before the parking
    /// is worse: only a clean drain clears one, a parked queue cannot produce
    /// a clean drain, and so an app would show "the Internet connection
    /// appears to be offline" for ever when the remedy is to sign in again.
    ///
    /// `count` is how many writes are waiting on it. Clear it with
    /// ``SyncEngine/retryAll(reason:)`` once a working credential is in place.
    case parked(reason: PendingMutationBlockReason, count: Int)
}
