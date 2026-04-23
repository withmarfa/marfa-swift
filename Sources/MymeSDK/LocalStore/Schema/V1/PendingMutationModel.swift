// MARK: - Predicate safety
//
// Every predicate-relevant column is a stored `String` or `Int`. The drain
// path sorts ascending by `createdAt`; cascade scans filter by `localId`
// or `kindRaw`. Never predicate against `kind` — predicate against
// `kindRaw` (the persisted String).

import Foundation
import SwiftData

@Model
final class PendingMutationModel {
    /// UUIDv4 string — preserved from the legacy schema so the SyncEngine
    /// can continue to identify mutations by id without coordination with
    /// the server (the server never sees this id).
    var id: String = ""

    /// Stored as `MutationKind.rawValue`. Use `kind` for typed access.
    var kindRaw: String = ""

    /// JSON-encoded payload matching the wire shape of the typed payload
    /// struct for this kind (CreateItemPayload, UpdateItemPayload, etc.).
    /// Stored as `String` rather than `Data` for parity with the legacy
    /// schema and to keep the row trivially inspectable in CloudKit's
    /// dashboard.
    var payloadJson: String = "{}"

    /// For `createItem` mutations, the stable client id used for server-side
    /// idempotency. Optional because most mutation kinds don't carry one.
    var sourceId: String?

    /// The local item/edge id this mutation operates on. Used by the cascade
    /// scan when a `createItem` is dropped permanently and dependent
    /// mutations need to be removed.
    var localId: String?

    /// ISO 8601 with fractional seconds. Drives drain order.
    var createdAt: String = ""

    /// Number of failed replay attempts. Incremented by `recordFailure`.
    var attemptCount: Int = 0

    /// Most recent error message from `recordFailure`. Optional.
    var lastError: String?

    init() {}

    // MARK: - Indexes

    #Index<PendingMutationModel>([\.createdAt], [\.localId], [\.kindRaw])
}

// MARK: - Ergonomic accessors

extension PendingMutationModel {
    /// Typed accessor for `kindRaw`. Falls back to `.createItem` if the
    /// stored value ever drifts off the closed enum (defensive against
    /// CloudKit-mirrored stores carrying values from a newer schema
    /// version — the safest default is the most-common mutation kind).
    var kind: MutationKind {
        get { MutationKind(rawValue: kindRaw) ?? .createItem }
        set { kindRaw = newValue.rawValue }
    }
}
