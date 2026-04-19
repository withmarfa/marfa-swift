import Foundation

/// Payload for ``SyncEvent/conflictAutoMerged``.
///
/// Replaces the v2.x bare-itemId payload. Carries enough detail for an app
/// to surface a meaningful toast — which fields were touched, which strategy
/// fired per field, and (when keep-both ran) the spawned sibling item id so
/// the app can navigate or scroll to it.
///
/// The single producer of this payload is ``SyncEngine`` during mutation
/// replay (`updateItem` paths that hit a 409 and resolved via
/// ``ConflictStrategy/auto``).
public struct ConflictAutoMergedPayload: Sendable, Hashable {
    /// The original item the client tried to update. Stable across retries.
    public let itemId: String

    /// The item id the merged update finally landed on. With the current
    /// retry-against-same-id flow this equals ``itemId``; reserved for
    /// future server-side flows that might rebind on resolution.
    public let mergedItemId: String

    /// When keep-both fired, the id of the spawned sibling tagged
    /// `conflicted-copy`. `nil` otherwise.
    public let conflictedCopyId: String?

    /// Sorted list of conflicting field names that fed into the merge.
    public let fields: [String]

    /// Per-field strategy that was applied. Keyed by JSON field name; values
    /// are the resolved ``MergePolicyStrategy``.
    public let strategy: [String: MergePolicyStrategy]

    public init(
        itemId: String,
        mergedItemId: String,
        conflictedCopyId: String?,
        fields: [String],
        strategy: [String: MergePolicyStrategy]
    ) {
        self.itemId = itemId
        self.mergedItemId = mergedItemId
        self.conflictedCopyId = conflictedCopyId
        self.fields = fields
        self.strategy = strategy
    }
}

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
    /// the post-merge state. Apps can use this to show a "merged" toast
    /// or navigate to a spawned conflicted-copy sibling.
    ///
    /// **v3.0 break:** previously `case conflictAutoMerged(itemId: String)`.
    /// Apps that subscribed to the bare itemId need to update the call
    /// site to read `payload.itemId` and check `payload.conflictedCopyId`
    /// to decide whether a sibling note exists to show.
    case conflictAutoMerged(payload: ConflictAutoMergedPayload)

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

    /// A queued mutation was dropped because the server rejected it with a
    /// permanent error (`400`, `403`, `404`). The mutation was removed from
    /// the queue and will not be retried — further retries would get the
    /// same result.
    ///
    /// Apps should surface this to the user (e.g., "Some edits couldn't be
    /// saved"). The `error` carries the specific failure (`ValidationError`,
    /// `NotFoundError`, `ForbiddenError`) so apps can tailor the message.
    ///
    /// `kind` is the raw value of `PendingMutationRecord.Kind` — stable
    /// across SDK versions (`createItem`, `updateItem`, `createEdge`, …).
    /// `itemId` is the target item ID (or edge ID / local ID, depending on
    /// the mutation); `nil` for records that don't carry one.
    case mutationDropped(kind: String, itemId: String?, attempt: Int, error: MymeError)
}
