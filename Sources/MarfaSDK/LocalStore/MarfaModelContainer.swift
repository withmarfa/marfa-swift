import Foundation
import SwiftData
import os

/// Single source of truth for constructing the SDK's `ModelContainer`.
///
/// Both `LocalStore` and `MutationQueue` are `@ModelActor`s sharing this
/// container. Cross-actor saves serialize at the SQLite layer.
///
/// The `cloudKitDatabase` parameter lets consumers opt into CloudKit sync
/// against a ubiquity container of their choosing. The default is `.none`
/// (pure local); pass `.automatic(containerIdentifier: "iCloud.…")` to
/// mirror the store through `NSPersistentCloudKitContainer`. The SwiftData
/// schema is CloudKit-compatible regardless of the mode chosen.
public enum MarfaModelContainer {
    private static let creationLock = NSLock()

    /// Builds a container at `path`, or an in-memory container when `path`
    /// is `:memory:` (the contract used by every test that wants an
    /// ephemeral database).
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
        // Core Data mutates process-global schema metadata while loading a
        // persistent store. Concurrent ModelContainer initialisation can race
        // inside that metadata setup and crash before Swift can report an error.
        creationLock.lock()
        defer { creationLock.unlock() }

        if path == ":memory:" {
            return try ModelContainer(
                for: Schema(MarfaSchemaV2.models),
                migrationPlan: MarfaMigrationPlan.self,
                configurations: ModelConfiguration(
                    "marfa",
                    schema: Schema(MarfaSchemaV2.models),
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                )
            )
        }
        let url = URL(fileURLWithPath: path)
        do {
            return try buildContainer(url: url, cloudKitDatabase: cloudKitDatabase)
        } catch {
            // Schema-mismatch recovery. When the on-disk store shape does not
            // match the current schema (e.g. a field was removed between SDK
            // versions and SwiftData's content hash changed), no migration stage
            // can bridge the gap inside a single binary. The pragmatic recovery
            // is to delete the stale store and reopen cleanly. The lightweight
            // V1 → V2 stage (added in 5.2.0) migrates cleanly and never hits
            // this path.
            //
            // Trade-off: any future migration failure (corrupt store, a custom
            // stage gone wrong) will also discard ``DroppedMutationModel`` rows.
            // The dropped-mutation log is therefore best-effort across migration
            // boundaries — apps should treat it as a recovery aid, not a durable
            // audit trail.
            let logger = Logger(subsystem: MarfaLogger.subsystem, category: "local")
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
            for: Schema(MarfaSchemaV2.models),
            migrationPlan: MarfaMigrationPlan.self,
            configurations: ModelConfiguration(
                "marfa",
                schema: Schema(MarfaSchemaV2.models),
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
