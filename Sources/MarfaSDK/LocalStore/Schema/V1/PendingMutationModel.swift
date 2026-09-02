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

    /// Stored as `PendingMutationState.rawValue`. Defaults to `"pending"`.
    /// `"inFlight"` is set by ``SyncEngine`` immediately before the
    /// transport call; cleared back to `"pending"` on transient failure
    /// (with `attemptCount++`). On success or permanent drop the record
    /// is removed, so `"failed"` is never a persisted state — consumers
    /// subscribe to ``SyncEvent/mutationDropped`` for permanent-fail UX.
    ///
    /// **Adding a property to this model breaks every store on disk, a
    /// defaulted one included.** Core Data refuses such a store with
    /// `Cannot use staged migration with an unknown model version`: the
    /// entity's shape moves while the versioned schema identifiers stay
    /// put, so no stage in ``MarfaMigrationPlan`` describes the step. The
    /// refusal does not surface as a crash, because
    /// ``MarfaModelContainer/make(path:cloudKitDatabase:)`` answers a store
    /// it cannot open by deleting it and building a fresh one — leaving a
    /// device that has quietly lost its queued writes and its
    /// dropped-mutation log. `ShippedStoreFixtureTests` fails on it.
    ///
    /// Changing this model therefore means a migration stage and a new
    /// versioned schema **that owns its own copies of the model classes**.
    /// A new schema listing these same compiled classes fixes nothing: the
    /// old version then hashes to the mutated shape too, and the stage has
    /// nothing to migrate from. ``MarfaMigrationPlan`` says how to do it, in
    /// the paragraph beginning "Adding V3 later".
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
