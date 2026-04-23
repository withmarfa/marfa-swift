import Foundation
import SwiftData

/// Schema migration plan for the SDK's on-device store.
///
/// V1 is the only schema version, so `stages` is empty.
///
/// Adding V2 later: copy `Schema/V1/` to `Schema/V2/`, mutate the models,
/// append `MymeSchemaV2.self` to `schemas`, and add a `MigrationStage`
/// (lightweight or custom) to `stages`. The plan must list every prior
/// version it knows how to migrate forward from.
@_spi(MymeSDKTestSupport) public enum MymeMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [MymeSchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}
