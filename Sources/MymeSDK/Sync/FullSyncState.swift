import Foundation

/// Snapshot of the engine's last "fully caught up" moment.
///
/// Consumers call ``SyncEngine/lastFullSync`` on app launch to decide
/// whether to trigger a fresh ``SyncEngine/performInitialSync(pageSize:)``
/// pull: a nil value or one older than the app's freshness budget is a
/// signal to pull; a recent value means the local store is already
/// caught up and the pull is redundant.
///
/// "Full sync" here means the SDK has reached a consistent cursor with
/// no pending local work. The engine writes this record at two points:
///
/// - After every successful drain cycle with zero transient errors — at
///   that moment the mutation queue is empty (or only holds
///   freshly-arrived writes) and the SSE cursor reflects every applied
///   event. `cursor` carries the Last-Event-ID at that moment.
/// - After ``SyncEngine/performInitialSync(pageSize:)`` completes. The
///   `cursor` may be nil here because an initial sync doesn't know what
///   the live SSE cursor will be until the stream opens next.
///
/// Persisted in the `sync_state` table under `last_full_sync_at` and
/// `last_full_sync_cursor`; survives app restarts and is keyed to the
/// on-disk store (not the client instance).
public struct FullSyncState: Sendable, Equatable {
    /// When the last full-sync checkpoint was written. Parsed from the
    /// same ISO 8601 format the rest of the SDK uses
    /// (`includingFractionalSeconds: true`).
    public let completedAt: Date

    /// The SSE `Last-Event-ID` at the moment of the checkpoint, or nil
    /// when the checkpoint was written by ``performInitialSync`` before
    /// any SSE events had been consumed.
    public let cursor: String?

    public init(completedAt: Date, cursor: String?) {
        self.completedAt = completedAt
        self.cursor = cursor
    }
}
