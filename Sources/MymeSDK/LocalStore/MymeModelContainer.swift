import Foundation
import SwiftData
import os

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
        do {
            return try buildContainer(url: url, cloudKitDatabase: cloudKitDatabase)
        } catch {
            // Schema-mismatch recovery: SDK 5.0 reshapes the local store
            // (library Bool -> tier String). Pre-5.0 stores cannot be
            // lightweight-migrated; the SDK has no real users yet, so the
            // pragmatic recovery is to delete the stale store and reopen.
            // If the second attempt fails too, surface the underlying error.
            let logger = Logger(subsystem: MymeLogger.subsystem, category: "local")
            logger.error("LocalStore open failed (\(error.localizedDescription, privacy: .public)); deleting store and recreating fresh under current schema.")
            removeStoreFiles(at: url)
            return try buildContainer(url: url, cloudKitDatabase: cloudKitDatabase)
        }
    }

    private static func buildContainer(
        url: URL,
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase
    ) throws -> ModelContainer {
        try ModelContainer(
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

    private static func removeStoreFiles(at url: URL) {
        let fm = FileManager.default
        let basePath = url.path
        for suffix in ["", "-wal", "-shm"] {
            let candidate = URL(fileURLWithPath: basePath + suffix)
            try? fm.removeItem(at: candidate)
        }
    }
}
