import Foundation
import SwiftData

/// V1 of the SwiftData schema. The first SwiftData-backed schema version
/// the SDK ships.
///
/// Its models are the frozen copies in ``FrozenV2``, not the live classes:
/// a version that listed the live classes would hash to whatever shape the
/// current build compiles, and a migration stage out of it would have nothing
/// to migrate from. See ``FrozenV2`` for why the *old* versions own the copies
/// rather than the new one.
///
/// Version `1.0.0` per Apple's `Schema.Version` semantics (major.minor.patch).
@_spi(MarfaSDKTestSupport) public enum MarfaSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        FrozenV2.sharedModels
    }
}
