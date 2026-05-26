import Foundation
import SwiftData

/// V2 of the SwiftData schema. Additive over V1: every V1 model is
/// referenced unchanged, plus the new ``DroppedMutationModel``.
///
/// V2 is the migration target for the lightweight stage in
/// ``MarfaMigrationPlan/stages``. Apps that opened a V1 store under
/// 5.0.x or 5.1.x land on V2 on first open after upgrading to 5.2.0;
/// existing rows survive untouched, and the new
/// ``DroppedMutationModel`` table appears empty.
///
/// Version `2.0.0` per Apple's `Schema.Version` semantics. The bump
/// is intentional: adding a model is a SwiftData schema change, even
/// when the migration is lightweight.
@_spi(MarfaSDKTestSupport) public enum MarfaSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        MarfaSchemaV1.models + [DroppedMutationModel.self]
    }
}
