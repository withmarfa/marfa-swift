import Foundation
import SwiftData

/// Schema migration plan for the SDK's on-device store.
///
/// Versions:
/// - V1 (5.0.x): post-TSC42 reset baseline.
/// - V2 (5.2.0): adds ``DroppedMutationModel``. Lightweight stage —
///   purely additive, no existing model changed.
///
/// Adding V3 later: if existing models change shape, copy
/// `Schema/V2/` (and any unchanged-from-V1 models referenced by V2)
/// into `Schema/V3/` so the V3 namespace owns its own copies, mutate
/// those copies, append `MymeSchemaV3.self` to `schemas`, and add a
/// `MigrationStage` describing the V2 → V3 transition. Pure-additive
/// V3 changes can keep referencing V2 models the same way V2
/// references V1 models — see ``MymeSchemaV2/models``.
@_spi(MymeSDKTestSupport) public enum MymeMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [MymeSchemaV1.self, MymeSchemaV2.self]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: MymeSchemaV1.self,
                toVersion: MymeSchemaV2.self
            )
        ]
    }
}
