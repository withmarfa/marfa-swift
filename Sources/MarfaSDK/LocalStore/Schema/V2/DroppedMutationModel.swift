// MARK: - Predicate safety
//
// Every predicate-relevant column is a stored `String` or `Int`. The
// dismissal paths filter on `id`, `localId`, or compare `droppedAt` as
// ISO 8601 string ordering (correct under the persisted format). Never
// predicate against `kind` — predicate against `kindRaw` (the persisted
// String).

import Foundation
import SwiftData

/// Persistent log of mutations the engine dropped permanently.
///
/// Inserted by ``MutationQueue/recordDropped(record:droppedAt:error:)``
/// when ``SyncEngine`` observes a permanent error (`MarfaError.isPermanent`)
/// during replay, atomically with removal of the live `PendingMutationModel`
/// row in the same `modelContext.save()`. Cascade orphans (downstream
/// mutations dropped because their parent `createItem` was rejected) land
/// here too — see `MutationQueue.dropMutationsReferencingLocalId`.
///
/// Apps observe these rows via ``DroppedMutationsQuery`` (vended from
/// ``MarfaStore/queryDroppedMutations()``) and clear them via
/// ``MutationQueue/dismissDropped(id:)``,
/// ``MutationQueue/dismissDroppedOlderThan(_:)``, or
/// ``MutationQueue/dismissAllDropped()``.
///
/// CloudKit-mirrored ready: no `#Unique`, every property defaults, no
/// relationships, enum-shaped fields stored via raw `String`.
@Model
final class DroppedMutationModel {
    /// UUIDv4 — preserved from the dead ``PendingMutationModel``'s id so
    /// callers can cross-reference any logs they captured at drop time.
    var id: String = ""

    /// Stored as ``MutationKind/rawValue``. Use `kind` for typed access.
    var kindRaw: String = ""

    /// JSON-encoded payload — verbatim from the live mutation row at the
    /// moment it was dropped (cascade rewrites already applied). Stored
    /// as `String` for parity with ``PendingMutationModel/payloadJson``
    /// and to keep CloudKit's dashboard inspectable.
    var payloadJson: String = "{}"

    /// The local item or edge id this mutation operated on, if any. Bulk
    /// mutations carry `nil`.
    var localId: String?

    /// ISO 8601 with fractional seconds — original
    /// ``PendingMutationRecord/createdAt`` from the live row. Lets apps
    /// surface "you queued this N hours ago" without a separate fetch.
    var enqueuedAt: String = ""

    /// ISO 8601 with fractional seconds — when the engine observed the
    /// permanent error and persisted this row. Drives the default sort
    /// order in ``DroppedMutationsQuery`` (newest first) and the
    /// `dismissDroppedOlderThan` cutoff.
    var droppedAt: String = ""

    /// Number of failed replay attempts before the permanent drop. The
    /// last attempt is the one that produced ``errorStatus`` /
    /// ``errorCode`` / ``errorMessage``.
    var attemptCount: Int = 0

    /// HTTP status code from the dropping error (typically 400, 403,
    /// 404). `0` is reserved for non-HTTP permanent failures (e.g. the
    /// blob-data-missing `ValidationError` synthesised inside the
    /// engine).
    var errorStatus: Int = 0

    /// ``MarfaError/code`` string (e.g. `"validation_error"`,
    /// `"not_found"`).
    var errorCode: String = ""

    /// ``MarfaError/message``. Capped at 1024 characters by
    /// ``MutationQueue/recordDropped(record:droppedAt:error:)`` so a
    /// pathological server response can't blow up CloudKit row sizes.
    var errorMessage: String = ""

    /// JSON-encoded ``MarfaError/details`` (`[String: JSONValue]`),
    /// or `nil` when the server response carried no `details` payload.
    /// Optional `String` rather than `Data` for parity with the other
    /// JSON fields in the schema.
    var errorDetailsJson: String?

    init() {}

    // MARK: - Indexes

    #Index<DroppedMutationModel>([\.droppedAt], [\.localId])
}

// MARK: - Ergonomic accessors

extension DroppedMutationModel {
    /// Typed accessor for ``kindRaw``. Falls back to `.createItem` for
    /// values from a future schema version — the conservative default,
    /// matching ``PendingMutationModel/kind``.
    var kind: MutationKind {
        get { MutationKind(rawValue: kindRaw) ?? .createItem }
        set { kindRaw = newValue.rawValue }
    }
}
