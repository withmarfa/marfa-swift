import Foundation
import SwiftData

/// V3 of the SwiftData schema, and the version the SDK currently opens stores
/// under. Its models are the live classes in `Schema/Models/`, so the current
/// shape is always readable in one place.
///
/// Seven changes over V2, all additive:
///
/// - ``MarfaItemModel/spaceId`` — the wire has carried `space_id` on an item
///   since before this store existed and the store dropped it on the way in,
///   so an app reading a synced item locally could not tell which space it
///   came from. The edge model has carried the same column all along.
/// - ``CachedTypeModel`` — the on-device copy of the space's type graph,
///   written by `MarfaClient.refreshCachedTypes()` and read to validate a
///   write before it is queued. It shipped here because a table is cheap to
///   add inside a migration that is happening anyway and expensive to add on
///   its own.
/// - ``PendingMutationModel/blockedReason`` — why a queued write is blocked.
///   It rode inside `lastError` as a string prefix while a column meant a
///   schema version. A store written by `16.x` still holds the prefix and is
///   read through `LegacyBlockedPrefix`.
/// - ``PendingMutationModel/idempotencyKey`` — the value sent as
///   `Idempotency-Key` on every attempt at a queued write.
/// - ``PendingMutationModel/refusalCount`` — attempts the server refused,
///   which is what the retry ceiling counts. Distinct from `attemptCount`,
///   which is every attempt made and is what a consumer displays.
/// - ``CachedBlobModel`` — bytes this device already has, so a blob it can
///   see does not need the network to be seen again. Distinct from
///   ``PendingBlobModel``, which is the outbound buffer and used to be the
///   only copy a device held.
/// - ``CachedBlobModel/isOwned`` — whether this device is the only thing
///   holding the bytes, which is the case for anything a client with no
///   server wrote. Eviction skips those rows and the size bound does not
///   refuse them, because there is nowhere for them to be fetched back from.
///
/// **V3 has never been released**, which is why all of these are here
/// rather than a fourth version. `v16.0.0` ships V2; V3 exists only on
/// `main`, so no device holds a store in this shape and adding to it costs
/// nobody a migration. The moment V3 ships that stops being true and the next
/// column needs V4 — `isOwned` above went in on the last day that was free.
///
/// Version `3.0.0` per Apple's `Schema.Version` semantics.
@_spi(MarfaSDKTestSupport) public enum MarfaSchemaV3: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            MarfaItemModel.self,
            MarfaEdgeModel.self,
            MarfaMetadataModel.self,
            PendingMutationModel.self,
            SyncStateModel.self,
            PendingBlobModel.self,
            DroppedMutationModel.self,
            CachedTypeModel.self,
            CachedBlobModel.self,
        ]
    }
}
