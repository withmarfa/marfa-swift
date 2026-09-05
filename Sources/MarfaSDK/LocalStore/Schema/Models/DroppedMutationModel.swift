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
/// Written by two paths. ``MutationQueue/recordDropped(record:droppedAt:error:)``
/// retires a whole record when ``SyncEngine`` observes a failure during
/// replay that no retry can clear, atomically with removal of the live
/// `PendingMutationModel` row in
/// the same `modelContext.save()`. That is `MarfaError.isPermanent` plus one
/// case the status alone cannot express: a `409` on a create, which the
/// engine classes permanent because the server acknowledges a repeat of the
/// caller's own id rather than refusing it. Cascade orphans (downstream
/// mutations dropped because their parent `createItem` was rejected) land
/// here too — see `MutationQueue.dropMutationsReferencingLocalId`.
///
/// ``MutationQueue/recordDroppedBulkEntries(record:entries:droppedAt:)`` is
/// the other, and it does not retire anything: a bulk call reached the
/// server and succeeded as a call, while some of the entries inside it were
/// refused. Those become rows here on their own, and the record retires
/// through the ordinary success path.
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
    /// The dead ``PendingMutationModel``'s id, so callers can cross-reference
    /// any logs they captured at drop time — a UUIDv4 for a record dropped
    /// whole.
    ///
    /// A row standing for one refused entry of a bulk call is that id with
    /// `#<key>` appended, where the key is the entry's position in the page
    /// or, for a bulk action, the item id it failed on. One call can leave
    /// many rows and they must not share an id: ``DroppedMutationRecord`` is
    /// `Identifiable` over this column, and duplicates collapse in a SwiftUI
    /// list built from ``DroppedMutationsQuery``.
    var id: String = ""

    /// Stored as ``MutationKind/rawValue``. Use `kind` for typed access.
    var kindRaw: String = ""

    /// JSON-encoded payload — verbatim from the live mutation row at the
    /// moment it was dropped (cascade rewrites already applied). Stored
    /// as `String` for parity with ``PendingMutationModel/payloadJson``
    /// and to keep CloudKit's dashboard inspectable.
    ///
    /// **Two shapes for a bulk kind, and the id is what tells them apart.**
    /// A row for a whole record holds the queue envelope, the entire page as
    /// it was enqueued. A row for one refused entry holds that entry alone,
    /// because a page can carry thousands and the refused one is the only
    /// part worth keeping. An id carrying a `#<key>` suffix is the second
    /// shape; a bare id is the first. Anything decoding this column for a
    /// bulk kind has to check which it has.
    var payloadJson: String = "{}"

    /// The local item or edge id this mutation operated on, if any.
    ///
    /// A bulk record dropped whole still carries `nil` — the page is not one
    /// row. A row for a single refused entry carries that entry's own id,
    /// which is the point of it: it names the row a person will notice is
    /// missing.
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

    /// Number of failed replay attempts before the row left the queue.
    ///
    /// **A discarded row is the exception**: nothing was attempted to produce
    /// its error, so the count is the row's own rather than one more than it.
    /// For every other producer the last attempt is the one that made
    /// ``errorStatus`` / ``errorCode`` / ``errorMessage``.
    var attemptCount: Int = 0

    /// HTTP status code from the dropping error (typically 400, 403, 404,
    /// or 409 on a create).
    ///
    /// `0` means the failure had no HTTP status of its own. Two cases: a
    /// single refused entry of a bulk call, where the call itself answered
    /// `200` and only the entry was rejected; and a write the app discarded
    /// through ``SyncEngine/discard(id:)``, which no server refused — the app
    /// stopped asking, which is a different thing and often follows attempts
    /// that were made and refused.
    ///
    /// **Branch on ``errorCode`` rather than on this**, which the second case
    /// makes plainly necessary: ``MarfaError/discardedByAppCode`` is the one
    /// row in this log that is not a refusal, and an app rendering it as one
    /// tells somebody their write failed when they withdrew it.
    var errorStatus: Int = 0

    /// ``MarfaError/code`` string (e.g. `"validation_error"`,
    /// `"not_found"`, `"conflict"`, `"type_mismatch"`).
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
