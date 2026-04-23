import Foundation
import SwiftData

/// V2 of the SwiftData schema. Additive changes over V1:
///
/// - `PendingMutationModel.lastAttemptAt: String?` — nil-default optional
///   column, populated by `MutationQueue.recordFailure(id:error:)`.
/// - `DroppedMutationModel` — new standalone model for the dropped-mutation
///   log (`SyncEngine.droppedMutations()` / `MymeStore.queryDroppedMutations()`).
///
/// Both changes are lightweight-migration-safe from V1: the new column has a
/// nil default, and adding a new table is always lightweight. The live
/// `PendingMutationModel` class carries the v2 shape; V1's `models` list
/// still names the same types — SwiftData tracks schema identity via the
/// version tuple, not the historical Swift class definition.
///
/// Version `2.0.0` per Apple's `Schema.Version` semantics (major.minor.patch).
@_spi(MymeSDKTestSupport) public enum MymeSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            MymeItemModel.self,
            MymeEdgeModel.self,
            MymeMetadataModel.self,
            PendingMutationModel.self,
            SyncStateModel.self,
            PendingBlobModel.self,
            DroppedMutationModel.self,
        ]
    }
}
