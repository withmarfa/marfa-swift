import Foundation
import SwiftData

/// Single source of truth for constructing the SDK's `ModelContainer`.
///
/// Both `LocalStore` and `MutationQueue` are `@ModelActor`s sharing this
/// container. Cross-actor saves serialise at the SQLite layer.
///
/// The `cloudKitDatabase` parameter lets consumers opt into CloudKit sync
/// against a ubiquity container of their choosing. The default is `.none`
/// (pure local); pass `.automatic(containerIdentifier: "iCloud.…")` to
/// mirror the store through `NSPersistentCloudKitContainer`. The SwiftData
/// schema is CloudKit-compatible regardless of the mode chosen.
public enum MymeModelContainer {
    /// Builds a container at `path`, or an in-memory container when `path`
    /// is `:memory:` (matches the legacy `LocalStore(path:)` contract used
    /// by every test that wants an ephemeral database).
    ///
    /// - Parameters:
    ///   - path: Filesystem path for the SQLite store, or `":memory:"` for
    ///     an ephemeral in-memory container.
    ///   - cloudKitDatabase: CloudKit sync mode. Defaults to `.none`.
    ///     In-memory containers always use `.none` regardless of this
    ///     argument — CloudKit mirroring requires a persistent store.
    public static func make(
        path: String,
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase = .none
    ) throws -> ModelContainer {
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
                cloudKitDatabase: cloudKitDatabase
            )
        )
    }
}
