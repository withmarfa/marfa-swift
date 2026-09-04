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

    /// A drain cycle just started — there's pending work in the
    /// mutation queue and the engine has begun replaying it. Fires
    /// once per cycle, after the engine has confirmed there is at
    /// least one record to replay (so an empty queue does not flap
    /// the state through `.syncing`). Consumers — including
    /// ``FullSyncStateQuery`` — use this as the "we are now syncing"
    /// signal without subscribing to
    /// ``ConnectionStateManager/stateUpdates`` directly.
    case syncing

    /// A sync round failed: the cycle could not drain. The error is the last
    /// one observed before the engine returned to the idle / offline state.
    ///
    /// A row that is *blocked* does not produce this. The engine has stopped
    /// retrying it, so it is not work the cycle failed to do — a cycle whose
    /// only outstanding rows are blocked reports ``SyncEvent/synced(at:)``.
    /// Watch ``SyncEvent/mutationBlocked(kind:itemId:reason:)`` and
    /// ``PendingMutationStatus/blocked(reason:attemptCount:lastError:)`` for
    /// those.
    case failed(error: Error)

    /// The mutation-queue replay auto-merged a server conflict using
    /// `ConflictStrategy.auto`. The original mutation succeeded against
    /// the post-merge state. Apps can use this to show a "merged" toast
    /// or navigate to a spawned conflicted-copy sibling.
    ///
    /// Read `payload.itemId` for the affected item and check
    /// `payload.conflictedCopyId` to determine whether a sibling item
    /// was created.
    case conflictAutoMerged(payload: ConflictAutoMergedPayload)

    /// An item was created on the server (either via SSE event from
    /// another client, or via local-mutation replay reconciliation).
    case itemCreated(id: String)

    /// An item was updated. Fires both for SSE-applied updates and
    /// successful mutation-queue replays of local edits.
    case itemUpdated(id: String)

    /// An item was deleted (soft delete / trashed).
    case itemDeleted(id: String)

    /// An item is gone for good and the local row has been removed.
    ///
    /// Not the same news as ``SyncEvent/itemDeleted(id:)``, which says the row
    /// was trashed and can come back. Nothing will ever correct a copy of a
    /// purged row, so a view still holding one is showing something that no
    /// longer exists anywhere.
    ///
    /// Fires for both routes a removal reaches a device by: the server's
    /// `item.purged` announcement, and the re-import, where a row purged while
    /// this device was away is simply absent from the answer.
    case itemPurged(id: String)

    /// An edge was created.
    case edgeCreated(id: String)

    /// An edge's properties were edited on another device, and the local row
    /// has been replaced with the server's. The endpoints and the id are
    /// unchanged — an edit that moved either would be a different edge.
    case edgeUpdated(id: String)

    /// An edge was deleted.
    case edgeDeleted(id: String)

    /// A write will not be retried, because repeating it would be answered
    /// the same way. Two things produce this, and they differ in what
    /// happened to the call.
    ///
    /// **A whole queued mutation was refused** — a `400`, `403` or `404`, or
    /// a `409` on a create. The request failed, the record is removed from
    /// the queue, and `error` carries that response's status and code.
    ///
    /// **One entry of a bulk call was refused** while the call itself
    /// succeeded. All three bulk doors answer per entry, so a page can be
    /// accepted with some of its writes rejected. The record retires through
    /// the ordinary success path rather than being dropped, one event fires
    /// per refused entry, and `error` carries the code the server gave that
    /// entry with `status == 0` — the call answered `200` and the entry's
    /// refusal never had a status of its own.
    ///
    /// Apps should surface this to the user (e.g., "Some edits couldn't be
    /// saved"). The `error` carries the specific failure (`ValidationError`,
    /// `NotFoundError`, `ForbiddenError`) so apps can tailor the message.
    ///
    /// `kind` is the raw value of `PendingMutationRecord.Kind` — stable
    /// across SDK versions (`createItem`, `updateItem`, `createEdge`, …).
    /// `itemId` is the target item ID (or edge ID / local ID, depending on
    /// the mutation); `nil` for records that don't carry one.
    case mutationDropped(kind: String, itemId: String?, attempt: Int, error: MarfaError)

    /// A queued mutation stopped, because its last failure is one no retry can
    /// clear until the app does something. Fires once, as the row becomes
    /// blocked.
    ///
    /// Distinct from ``SyncEvent/mutationDropped`` in the half that matters to
    /// a person: the write is still there. It is skipped by the drain rather
    /// than discarded, it does not make the cycle report
    /// ``SyncEvent/failed(error:)``, and ``SyncEngine/retry(id:)`` returns it
    /// to the queue once the obstacle is gone. A `resolverMissing` block needs
    /// no call at all — registering a resolver is enough.
    ///
    /// `kind` is the raw value of ``MutationKind``, matching
    /// ``SyncEvent/mutationDropped``'s field. `itemId` is the target item, edge
    /// or local id, and `nil` for records that carry none.
    case mutationBlocked(kind: String, itemId: String?, reason: PendingMutationBlockReason)

    /// The local store could not be opened and was rebuilt empty, so this
    /// device is starting from nothing until the first import finishes.
    ///
    /// Emitted once, by ``SyncEngine/start()``, because the store is opened
    /// before an engine exists to announce it. Subscribe to ``SyncEngine/events``
    /// before calling `start()` and the announcement arrives there; the same
    /// value is also readable synchronously as ``MarfaClient/storeRecovery``.
    ///
    /// Worth surfacing rather than logging. The payload names the directory
    /// the old store was moved to and how many queued writes, dead letters and
    /// queued uploads were salvaged out of it — the things the server cannot
    /// send back.
    case storeRecovered(StoreRecovery)

    /// A blob upload has started. Fires once per upload attempt, before
    /// any bytes hit the network. `totalBytes` comes from the queued
    /// payload — the same value `BlobUploadResponse.size` returned when
    /// the upload was enqueued.
    ///
    /// ``BlobUploadProgressQuery`` consumes this to open a progress
    /// entry in its `uploads` dict keyed by `hash`; apps that want a
    /// "upload started" affordance can subscribe to the events stream
    /// directly.
    case blobUploadStarted(hash: String, totalBytes: Int64)

    /// Incremental upload progress. Fires zero or more times between
    /// ``SyncEvent/blobUploadStarted`` and a terminal
    /// ``SyncEvent/blobUploadCompleted`` / ``SyncEvent/blobUploadFailed``.
    /// `bytesUploaded` is monotonically non-decreasing within a single
    /// attempt; on retry after a transient failure the counter resets
    /// to zero with a fresh `blobUploadStarted`.
    case blobUploadProgress(hash: String, bytesUploaded: Int64, totalBytes: Int64)

    /// A blob upload finished successfully. The pending-blob row has
    /// been removed from the local store; subsequent reads for the
    /// same hash go through the normal blob-download path.
    case blobUploadCompleted(hash: String)

    /// A blob upload failed. For transient failures the engine will
    /// retry on the next replay cycle — consumers will see another
    /// ``SyncEvent/blobUploadStarted`` for the same hash when that
    /// happens. For permanent failures the mutation is dropped, and a
    /// matching ``SyncEvent/mutationDropped`` follows.
    case blobUploadFailed(hash: String, error: MarfaError)
}
