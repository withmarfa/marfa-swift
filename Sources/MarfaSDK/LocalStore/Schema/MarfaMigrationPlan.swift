import Foundation
import SwiftData

/// Schema migration plan for the SDK's on-device store.
///
/// Versions:
/// - V1 (5.0.x): initial versioned schema. `tier` is a `String`; the
///   store is CloudKit-compatible from this baseline.
/// - V2 (5.2.0): adds ``DroppedMutationModel``. Lightweight stage —
///   purely additive, no existing model changed.
///
/// 7.0.0 dropped `originRaw` from ``MarfaItemModel`` alongside the
/// wire-side removal of `Item.origin`. That change keeps the V2
/// versioned schema but mutates `MarfaItemModel`'s shape in place —
/// SwiftData computes a different content hash than v6.x stores wrote.
/// No migration stage can bridge the two within a single binary
/// (SwiftData hashes the class shape at compile time, not at write time),
/// so v6.x → v7.0 takes the schema-mismatch recovery path in
/// ``MarfaModelContainer/make(path:cloudKitDatabase:)``: the old store
/// is deleted and a fresh one is built. Pre-release pragmatism; data
/// loss is acceptable before any real users depend on the store.
///
/// Adding V3 later: if existing models change shape, copy
/// `Schema/V2/` (and any unchanged-from-V1 models referenced by V2)
/// into `Schema/V3/` so the V3 namespace owns its own copies, mutate
/// those copies, append `MarfaSchemaV3.self` to `schemas`, and add a
/// `MigrationStage` describing the V2 → V3 transition. Pure-additive
/// V3 changes can keep referencing V2 models the same way V2
/// references V1 models — see ``MarfaSchemaV2/models``.
@_spi(MarfaSDKTestSupport) public enum MarfaMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [MarfaSchemaV1.self, MarfaSchemaV2.self]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: MarfaSchemaV1.self,
                toVersion: MarfaSchemaV2.self
            )
        ]
    }
}
