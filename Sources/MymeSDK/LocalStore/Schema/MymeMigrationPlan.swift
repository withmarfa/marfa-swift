import Foundation
import SwiftData

/// Schema migration plan for the SDK's on-device store.
///
/// V1 is the first SwiftData schema the SDK ships. `stages` is empty
/// because there is no prior SwiftData version to migrate from — the
/// GRDB-era stores from SDK 3.5 and earlier are scrapped on upgrade
/// (the SDK is pre-release, no users depend on automatic migration).
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
