import Foundation
import SwiftData

/// V2 of the SwiftData schema. Additive over V1: every V1 model unchanged,
/// plus ``FrozenV2/DroppedMutationModel``.
///
/// Its models are the frozen copies in ``FrozenV2`` for the same reason V1's
/// are. Apps that opened a V1 store under 5.0.x or 5.1.x landed on V2 on first
/// open after upgrading to 5.2.0; existing rows survived untouched and the new
/// dropped-mutation table appeared empty.
///
/// Version `2.0.0` per Apple's `Schema.Version` semantics. The bump is
/// intentional: adding a model is a SwiftData schema change, even when the
/// migration is lightweight.
@_spi(MarfaSDKTestSupport) public enum MarfaSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        FrozenV2.sharedModels + [FrozenV2.DroppedMutationModel.self]
    }
}
