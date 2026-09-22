import Foundation
import SwiftData

/// Schema migration plan for the SDK's on-device store.
///
/// Versions:
/// - V1 (5.0.x): initial versioned schema.
/// - V2 (5.2.0): adds a dropped-mutation table. Additive, so the stage is
///   lightweight.
/// - V3: adds `space_id` to the item model, the cached-types table, and
///   `blocked_reason` to the pending-mutation model.
///   Additive on both counts, so the stage is lightweight again.
///
/// ## Where the model classes live
///
/// The live `@Model` classes in `Schema/Models/` are always the *current*
/// version — V3 today. Every version before it owns frozen copies, in
/// ``FrozenV2``. The alternative arrangement, where the new version owns the
/// copies, would mean repointing ``LocalStore``, ``MutationQueue``, every
/// reactive query and every test at a nested type on each schema change; this
/// one leaves all of that alone and confines the churn to one file of history.
///
/// Adding a version therefore means: copy the live classes into a new frozen
/// namespace at their current shape, point the outgoing version at it, change
/// the live classes, add the new `MarfaSchemaVn` listing them, and append a
/// stage. `SchemaMigrationTests` checks that the frozen copies still hash the
/// way the versions they stand for hashed, so getting the copy wrong fails
/// there rather than on a device.
///
/// ## The current version is open until it ships, and that is worth checking
///
/// **A version only has to be frozen once a store exists that records it.**
/// While a version is unreleased no device holds a store in its shape, so an
/// additive column added to a live model joins it rather than forcing a new
/// one. The cost to a device is unchanged either way: it takes the stage it
/// was going to take, carrying whatever shape that version has when it ships.
///
/// **V3 is closed.** Devices hold V3 stores, so the next column needs a V4 and
/// a V3-to-V4 stage.
///
/// The one consequence worth knowing is developer-only. A store built from an
/// intermediate state of an open version records `3.0.0` while holding a shape
/// no committed version describes, so a later build refuses it with `Cannot
/// use staged migration with an unknown model version` and takes the
/// quarantine path. That is the fail-safe working, on a store nobody shipped.
///
/// ## What happens when no stage describes the store
///
/// A store whose recorded entity hashes match no version in `schemas` is
/// refused by Core Data with `Cannot use staged migration with an unknown
/// model version`. That is not a corruption and not a bug in the store — the
/// file is a perfectly readable database that this build's object model cannot
/// be attached to. ``MarfaModelContainer/open(path:cloudKitDatabase:)`` moves
/// such a store aside and salvages what only it holds rather than deleting it.
@_spi(MarfaSDKTestSupport) public enum MarfaMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [MarfaSchemaV1.self, MarfaSchemaV2.self, MarfaSchemaV3.self]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: MarfaSchemaV1.self,
                toVersion: MarfaSchemaV2.self
            ),
            .lightweight(
                fromVersion: MarfaSchemaV2.self,
                toVersion: MarfaSchemaV3.self
            ),
        ]
    }

    /// The version a store this build writes is stamped with.
    static var current: any VersionedSchema.Type { MarfaSchemaV3.self }
}
