import Foundation
import SwiftData

/// Schema migration plan for the SDK's on-device store.
///
/// V1 shipped in SDK 4.0.0. V2 ships in 4.3.0 with two additive changes —
/// `PendingMutationModel.lastAttemptAt` (optional column, nil default) and
/// `DroppedMutationModel` (new standalone table). Both are lightweight-safe.
///
/// Adding V3 later: add `Schema/V3/MymeSchemaV3.swift`, append it to
/// `schemas`, and append a `MigrationStage` describing the V2 → V3 step.
/// The plan must list every prior version it knows how to migrate forward
/// from; removing a version breaks users still on it.
@_spi(MymeSDKTestSupport) public enum MymeMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [MymeSchemaV1.self, MymeSchemaV2.self]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: MymeSchemaV1.self, toVersion: MymeSchemaV2.self)
        ]
    }
}
