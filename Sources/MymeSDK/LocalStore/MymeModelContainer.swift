import Foundation
import SwiftData

/// Single source of truth for constructing the SDK's `ModelContainer`.
///
/// Both `LocalStore` and `MutationQueue` are `@ModelActor`s sharing this
/// container. Cross-actor saves serialise at the SQLite layer.
///
/// Phase 1 ships with `cloudKitDatabase: .none` — CloudKit sync is unlocked
/// (the schema is CloudKit-compatible) but not enabled. Phase 2 (the Notes
/// app's iCloud sync work) flips this to `.automatic` against the consumer
/// app's ubiquity container.
///
/// Exposed via `@_spi(MymeSDKTestSupport)` so `MymeSDKTestSupport` can
/// build in-memory containers for unit tests without leaking the
/// constructor into the public SDK surface.
@_spi(MymeSDKTestSupport) public enum MymeModelContainer {
    /// Builds a container at `path`, or an in-memory container when `path`
    /// is `:memory:` (matches the legacy `LocalStore(path:)` contract used
    /// by every test that wants an ephemeral database).
    public static func make(path: String) throws -> ModelContainer {
        if path == ":memory:" {
            return try ModelContainer(
                for: Schema(MymeSchemaV1.models),
                migrationPlan: MymeMigrationPlan.self,
                configurations: ModelConfiguration(
                    "myme",
                    schema: Schema(MymeSchemaV1.models),
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                )
            )
        }
        let url = URL(fileURLWithPath: path)
        return try ModelContainer(
            for: Schema(MymeSchemaV1.models),
            migrationPlan: MymeMigrationPlan.self,
            configurations: ModelConfiguration(
                "myme",
                schema: Schema(MymeSchemaV1.models),
                url: url,
                allowsSave: true,
                cloudKitDatabase: .none
            )
        )
    }
}
