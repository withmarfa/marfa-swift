import Foundation

/// Sendable snapshot of a mutation the ``SyncEngine`` dropped permanently.
///
/// When a queued mutation hits a permanent error (400/403/404), the
/// engine removes it from ``MutationQueue`` and persists this record so
/// the content isn't lost — consumers can list, purge, or rebuild the
/// original call from `payloadJson`.
///
/// Obtain via ``SyncEngine/droppedMutations()`` or
/// ``MymeStore/queryDroppedMutations()``.
public struct DroppedMutationRecord: Sendable, Equatable {
    /// The original ``PendingMutationRecord/id`` — stable across the
    /// drop; consumers can pass it to
    /// ``SyncEngine/purgeDroppedMutation(id:)``.
    public let id: String

    /// What kind of operation was dropped.
    public let kind: MutationKind

    /// The local item or edge id this mutation targeted. Nil for
    /// kind-less operations (`bulk`, `bulkAction`, `uploadBlob`).
    public let itemId: String?

    /// Number of failed replay attempts before the drop. `0` when the
    /// first attempt hit a permanent error; higher when transient
    /// errors preceded the permanent one.
    public let attemptCount: Int

    /// When the mutation was dropped.
    public let droppedAt: Date

    /// ``MymeError/code`` from the permanent error (e.g.
    /// `"not_found"`, `"validation_error"`).
    public let errorCode: String

    /// HTTP status from the permanent error. 400, 403, or 404 for
    /// non-cascade drops; cascade drops inherit the root error's status.
    public let errorStatus: Int

    /// Human-readable error message from ``MymeError/message``.
    public let errorMessage: String

    /// Full original payload JSON, preserved from the pending mutation
    /// row. Consumers that implement a retry UI can decode this into
    /// the appropriate input type (e.g. ``CreateItemInput``) and resubmit.
    public let payloadJson: String

    public init(
        id: String,
        kind: MutationKind,
        itemId: String?,
        attemptCount: Int,
        droppedAt: Date,
        errorCode: String,
        errorStatus: Int,
        errorMessage: String,
        payloadJson: String
    ) {
        self.id = id
        self.kind = kind
        self.itemId = itemId
        self.attemptCount = attemptCount
        self.droppedAt = droppedAt
        self.errorCode = errorCode
        self.errorStatus = errorStatus
        self.errorMessage = errorMessage
        self.payloadJson = payloadJson
    }
}
