// MARK: - Predicate safety
//
// Every predicate-relevant column is a stored `String` or `Int`. Consumers
// typically list dropped mutations sorted by `droppedAt` desc; uniqueness is
// enforced by construction (one row per dropped PendingMutation id). Never
// predicate against `kind` — predicate against `kindRaw` (the persisted
// String). See `Schema/PredicateConventions.swift`.

import Foundation
import SwiftData

/// Persisted record of a mutation the `SyncEngine` dropped permanently.
///
/// When a queued mutation hits a permanent error (`MymeError.isPermanent`
/// — 400, 403, 404), the engine removes the row from `PendingMutationModel`
/// and drops a copy here so consumers can surface, retry manually, or purge
/// it later. Before 4.3.0 the content was lost except to `os.Logger`.
///
/// Added in schema v2. CloudKit-safe by construction: no `#Unique`, every
/// property has a default, no relationships, no `.deny` rules, no reserved
/// names. Codable enums stored as `String` rawValue via `kindRaw`.
@Model
final class DroppedMutationModel {
    /// The original `PendingMutationModel.id` (UUIDv4). One row per dropped
    /// mutation — cascade drops insert N rows, one per dependent mutation.
    var id: String = ""

    /// Stored as `MutationKind.rawValue`. Use `kind` for typed access.
    var kindRaw: String = ""

    /// The local item/edge id this mutation targeted. Nil for mutations
    /// without a target (e.g. `bulk`).
    var itemId: String?

    /// Number of failed replay attempts before the drop. `0` for the
    /// fast-path where the first attempt hit a permanent error; higher
    /// when transient errors preceded the permanent one.
    var attemptCount: Int = 0

    /// ISO 8601 with fractional seconds. When the engine dropped the row.
    var droppedAt: String = ""

    /// `MymeError.code` — e.g. `"not_found"`, `"validation_error"`.
    var errorCode: String = ""

    /// HTTP status from the permanent error. Always 400, 403, or 404 for
    /// non-cascade drops; cascade drops inherit the root error's status.
    var errorStatus: Int = 0

    /// Human-readable error message, copied from `MymeError.message`.
    var errorMessage: String = ""

    /// Full original payload JSON, preserved verbatim from the pending
    /// mutation row so a consumer UI can rebuild the input for a manual
    /// retry. Inline `String` — payloads are typically under a few KB
    /// (the only large-payload case, `uploadBlob`, references a blob by
    /// content hash rather than inlining bytes).
    var payloadJson: String = "{}"

    init() {}

    // MARK: - Indexes

    #Index<DroppedMutationModel>([\.id], [\.droppedAt], [\.kindRaw])
}

// MARK: - Ergonomic accessors

extension DroppedMutationModel {
    /// Typed accessor for `kindRaw`. Falls back to `.createItem` if the
    /// stored value drifts off the closed enum — the same defensive default
    /// as `PendingMutationModel.kind`.
    var kind: MutationKind {
        get { MutationKind(rawValue: kindRaw) ?? .createItem }
        set { kindRaw = newValue.rawValue }
    }
}
