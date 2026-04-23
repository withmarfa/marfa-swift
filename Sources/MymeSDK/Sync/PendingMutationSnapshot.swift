import Foundation

/// Status of a single pending mutation.
///
/// Consumers can map this directly to UI — show `.pending` dimly, show
/// `.inFlight` with a spinner, show `.failed` with an error affordance
/// and the last attempt time. The older boolean `hasPendingMutations` on
/// ``SyncEngine`` remains for simple "anything pending?" callers.
public enum PendingMutationStatus: Sendable, Equatable {
    /// Queued and waiting. Either hasn't been attempted yet, or the
    /// previous attempt succeeded and this is a fresh enqueue — `.pending`
    /// when `attemptCount == 0` AND the mutation isn't currently in flight.
    case pending

    /// Currently being dispatched by ``SyncEngine`` (a network round-trip
    /// is in flight). Derived from the engine's in-memory in-flight set,
    /// not persisted — `.inFlight` never appears after a process restart.
    case inFlight

    /// The previous replay attempt failed. `lastError` carries the message
    /// ``MutationQueue/recordFailure(id:error:)`` recorded;
    /// `lastAttemptAt` is nil only for rows that predate schema v2
    /// (migrated stores without a recorded attempt time).
    case failed(lastError: String, lastAttemptAt: Date?)
}

/// Snapshot of a queued mutation with its current status.
///
/// Trimmed view of ``PendingMutationRecord`` for consumer UIs: leaves out
/// `payloadJson` and `sourceId` (internal replay details) and maps
/// ISO 8601 timestamps to ``Date`` for convenience.
public struct PendingMutationSnapshot: Sendable, Equatable {
    /// The queue-internal UUIDv4 — stable across the mutation's lifetime
    /// until it's removed on success or dropped on permanent failure.
    public let id: String

    /// What kind of operation is queued (createItem, updateItem, …).
    public let kind: MutationKind

    /// The local item or edge id this mutation targets, if any. Nil for
    /// kind-less operations (`bulk`, `bulkAction`, `uploadBlob`).
    public let itemId: String?

    /// When the mutation was first enqueued. Drives drain order.
    public let createdAt: Date

    /// Number of failed replay attempts. `0` until the first transient
    /// failure lands; permanent failures remove the row and persist a
    /// ``DroppedMutationRecord`` instead (see
    /// ``SyncEngine/droppedMutations()``).
    public let attemptCount: Int

    /// Current status — `.pending`, `.inFlight`, or `.failed(...)`.
    public let status: PendingMutationStatus

    public init(
        id: String,
        kind: MutationKind,
        itemId: String?,
        createdAt: Date,
        attemptCount: Int,
        status: PendingMutationStatus
    ) {
        self.id = id
        self.kind = kind
        self.itemId = itemId
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.status = status
    }
}
