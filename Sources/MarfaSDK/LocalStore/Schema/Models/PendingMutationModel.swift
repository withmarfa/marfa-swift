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
    /// UUIDv4 string. The SyncEngine uses this to identify mutations
    /// locally; the server never sees it.
    var id: String = ""

    /// Stored as `MutationKind.rawValue`. Use `kind` for typed access.
    var kindRaw: String = ""

    /// JSON-encoded payload matching the wire shape of the typed payload
    /// struct for this kind (CreateItemPayload, UpdateItemPayload, etc.).
    /// Stored as `String` rather than `Data` to keep the row trivially
    /// inspectable in CloudKit's dashboard.
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

    /// Why this row is blocked, as `PendingMutationBlockReason.rawValue`, or
    /// `nil` when it is not blocked.
    ///
    /// **This used to ride inside `lastError` as a `[blocked:<reason>]` string
    /// prefix**, parsed back out at the actor boundary. The rationale written
    /// at the time was sound — adding a property to a `@Model` needs a schema
    /// version, and one added for this alone would cost every device a
    /// migration. V3 has never shipped, so this one costs nobody anything.
    ///
    /// The smuggling had a failure the column does not: an unrecognized token
    /// decoded as ``PendingMutationBlockReason/retriesExhausted``, so a build
    /// meeting a reason a newer build had written was told the row would never
    /// recover — a reason that clears itself, like a missing resolver, read as
    /// one that does not.
    var blockedReason: String?

    /// Stored as `PendingMutationState.rawValue`. Defaults to `"pending"`.
    /// `"inFlight"` is set by ``SyncEngine`` immediately before the
    /// transport call; cleared back to `"pending"` on transient failure
    /// (with `attemptCount++`). On success or permanent drop the record
    /// is removed, so `"failed"` is never a persisted state — consumers
    /// subscribe to ``SyncEvent/mutationDropped`` for permanent-fail UX.
    ///
    /// **Adding a property to this model needs a schema version, not just a
    /// default.** Core Data refuses a store whose entity hashes match no
    /// version in ``MarfaMigrationPlan`` — the entity's shape moves while the
    /// versioned schema identifiers stay put, so no stage describes the step.
    /// A defaulted column is no exemption; the hash covers the shape, not the
    /// values. `ShippedStoreFixtureTests` fails on it, against a store a real
    /// build wrote.
    ///
    /// So changing this model means a new versioned schema **that leaves the
    /// previous one holding frozen copies of the model classes** —
    /// ``MarfaMigrationPlan`` sets out the steps. A new schema listing these
    /// same compiled classes fixes nothing: the old version then hashes to the
    /// mutated shape too, and the stage has nothing to migrate from.
    ///
    /// A new *value* in this column costs nothing by contrast, because
    /// SwiftData never inspects what a string holds — so a new
    /// ``PendingMutationState`` case is the cheap way to extend the
    /// lifecycle, and a new column is not.
    var stateRaw: String = PendingMutationState.pending.rawValue

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

    /// Typed accessor for `stateRaw`. Falls back to `.pending` for
    /// unknown values — the conservative default, making the record
    /// eligible for a fresh replay rather than hiding it.
    var state: PendingMutationState {
        get { PendingMutationState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }
}

// MARK: - PendingMutationState

/// Lifecycle state of a pending mutation as persisted in
/// ``PendingMutationModel``.
///
/// - `pending` — queued, not currently being replayed. A `pending`
///   record with `attemptCount > 0` / `lastError != nil` is awaiting a
///   retry after a transient failure.
/// - `inFlight` — the sync engine is mid-replay on this record. Set
///   immediately before the transport call; cleared back to `pending`
///   on transient failure. On success or permanent drop the row is
///   removed from the queue, so `inFlight` is never observed for a
///   "stuck" record — crashed or cancelled replays recover the next
///   time the engine starts draining.
///
/// - `blocked` — the last failure was one no retry can clear until the app
///   changes something. The drain skips the row and the cycle does not report
///   failure for it; ``PendingMutationBlockReason`` says why, and
///   ``SyncEngine/retry(id:)`` puts it back in the queue. A `resolverMissing`
///   block is the exception that clears itself, because the next drain that
///   finds a registered resolver replays it.
///
/// Round-tripped through `stateRaw` — keep new cases additive so
/// CloudKit-mirrored stores from older clients don't fail to decode.
public enum PendingMutationState: String, Codable, Sendable, CaseIterable {
    case pending
    case inFlight
    case blocked
}
