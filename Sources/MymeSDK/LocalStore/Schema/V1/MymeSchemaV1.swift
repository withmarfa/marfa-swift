import Foundation
import SwiftData

/// V1 of the SwiftData schema. The first SwiftData-backed schema version
/// the SDK ships. Every subsequent schema (V2, V3, …) lives in a sibling
/// `Schema/V<n>/` directory and is appended to `MymeMigrationPlan.schemas`
/// alongside a `MigrationStage` describing how to migrate from V<n-1>.
///
/// Version `1.0.0` per Apple's `Schema.Version` semantics (major.minor.patch).
/// `models` is the canonical list of `@Model` types in this version — the
/// `ModelContainer` constructor reflects on these for validation.
enum MymeSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            MymeItemModel.self,
            MymeEdgeModel.self,
            MymeMetadataModel.self,
            PendingMutationModel.self,
            SyncStateModel.self,
            PendingBlobModel.self,
        ]
    }
}
