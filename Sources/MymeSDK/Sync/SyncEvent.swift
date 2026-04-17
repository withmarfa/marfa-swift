import Foundation

/// A typed event emitted by `SyncEngine.events`.
///
/// Apps subscribe to the engine's `events` stream to react to sync activity
/// (e.g. updating a "Last synced" footer, surfacing a merge toast). Each
/// case carries enough context for the consumer to act without re-fetching.
///
/// The stream is shared (single producer, multiple consumers receive their
/// own continuation). Past events are not replayed to late subscribers.
public enum SyncEvent: Sendable {
    /// A full sync round completed — both the SSE event drain and the
    /// mutation-queue replay finished without an outstanding error.
    case synced(at: Date)

    /// A sync round failed. The error is the last one observed before
    /// the engine returned to the idle / offline state.
    case failed(error: Error)

    /// The mutation-queue replay auto-merged a server conflict using
    /// `ConflictStrategy.auto`. The original mutation succeeded against
    /// the post-merge state. Apps can use this to show a "merged" toast.
    case conflictAutoMerged(itemId: String)

    /// An item was created on the server (either via SSE event from
    /// another client, or via local-mutation replay reconciliation).
    case itemCreated(id: String)

    /// An item was updated. Fires both for SSE-applied updates and
    /// successful mutation-queue replays of local edits.
    case itemUpdated(id: String)

    /// An item was deleted (soft delete / trashed).
    case itemDeleted(id: String)

    /// An edge was created.
    case edgeCreated(id: String)

    /// An edge was deleted.
    case edgeDeleted(id: String)
}
