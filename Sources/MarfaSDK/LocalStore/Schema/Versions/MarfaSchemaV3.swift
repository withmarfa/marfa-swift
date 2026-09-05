import Foundation
import SwiftData

/// V3 of the SwiftData schema, and the version the SDK currently opens stores
/// under. Its models are the live classes in `Schema/Models/`, so the current
/// shape is always readable in one place.
///
/// Three changes over V2, all additive:
///
/// - ``MarfaItemModel/spaceId`` — the wire has carried `space_id` on an item
///   since before this store existed and the store dropped it on the way in,
///   so an app reading a synced item locally could not tell which space it
///   came from. The edge model has carried the same column all along.
/// - ``CachedTypeModel`` — the on-device copy of the space's type graph.
///   Nothing writes it yet. It ships here because a table is cheap to add
///   inside a migration that is happening anyway and expensive to add on its
///   own: the local type registry would otherwise have to open a second
///   migration for one table.
/// - ``PendingMutationModel/blockedReason`` — why a queued write is blocked.
///   It rode inside `lastError` as a string prefix while a column meant a
///   schema version; V3 has never shipped, so it costs nobody a migration.
///   A store written by `16.x` still holds the prefix and is read through
///   `LegacyBlockedPrefix`.
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
        ]
    }
}
