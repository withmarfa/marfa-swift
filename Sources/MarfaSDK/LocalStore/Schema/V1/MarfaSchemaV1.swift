import Foundation
import SwiftData

/// V1 of the SwiftData schema. The first SwiftData-backed schema version
/// the SDK ships. Every subsequent schema (V2, V3, …) lives in a sibling
/// `Schema/V<n>/` directory and is appended to `MarfaMigrationPlan.schemas`
/// alongside a `MigrationStage` describing how to migrate from V<n-1>.
///
/// Version `1.0.0` per Apple's `Schema.Version` semantics (major.minor.patch).
/// `models` is the canonical list of `@Model` types in this version — the
/// `ModelContainer` constructor reflects on these for validation.
@_spi(MarfaSDKTestSupport) public enum MarfaSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            MarfaItemModel.self,
            MarfaEdgeModel.self,
            MarfaMetadataModel.self,
            PendingMutationModel.self,
            SyncStateModel.self,
            PendingBlobModel.self,
        ]
    }
}
