import CoreData
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
///
/// ## When a store cannot be opened
///
/// Almost always it can: a store written by an older build migrates forward
/// through ``MarfaMigrationPlan``. The exception is a store whose shape
/// matches no version this build knows — an upgrade across a schema change
/// that shipped without a stage, or a downgrade onto a store a newer build
/// wrote. Such a store is **moved aside, never deleted**, and what only it
/// held is written out beside it. See
/// ``open(path:cloudKitDatabase:)`` and ``StoreRecovery``.
public enum MarfaModelContainer {
    private static let creationLock = NSLock()

    /// Builds a container at `path`, or an in-memory container when `path`
    /// is `:memory:` (the contract used by every test that wants an
    /// ephemeral database).
    ///
    /// Discards the answer to "did this store have to be rebuilt". Call
    /// ``open(path:cloudKitDatabase:)`` instead where something in the app
    /// should react to that.
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
        try open(path: path, cloudKitDatabase: cloudKitDatabase).container
    }

    /// Builds a container at `path` and says whether the store on disk
    /// survived it.
    ///
    /// ``StoreOpenResult/recovery`` is `nil` for every ordinary open,
    /// including one that migrates an older store forward. It is non-`nil`
    /// only when this build could not use the store at all, in which case the
    /// old store has been moved into a quarantine directory, the queue and the
    /// cursor have been written out beside it, and the container returned is a
    /// fresh empty one that will re-hydrate from the server.
    ///
    /// - Throws: ``LocalStoreError/storeQuarantineFailed(_:)`` when a store
    ///   that could not be opened also could not be moved aside. Nothing is
    ///   deleted in that case: an app that cannot preserve the queue is told
    ///   so rather than quietly starting over without it.
    public static func open(
        path: String,
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase = .none
    ) throws -> StoreOpenResult {
        try open(path: path, cloudKitDatabase: cloudKitDatabase, fileManager: .default)
    }

    /// The same open, over a file manager a test can substitute.
    ///
    /// The store-side counterpart to substituting a `Transport`. Every failure
    /// this path exists to survive is a filesystem refusing something, and the
    /// ones worth pinning cannot be staged on a real filesystem: anything that
    /// stops a rename — a permission, a lock, an immutable flag — stops the
    /// removal beside it too, so the branch that removes what could not be
    /// moved is unreachable from a test that has only real files to work with.
    /// A full disk is the case that separates them, and it is not one a test
    /// can arrange.
    internal static func open(
        path: String,
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase = .none,
        fileManager: FileManager
    ) throws -> StoreOpenResult {
        try withCreationLock {
            try openUnlocked(
                path: path,
                cloudKitDatabase: cloudKitDatabase,
                fileManager: fileManager
            )
        }
    }

    /// Coordinates every ModelContainer constructor owned by this package.
    /// Tests that must build an older schema use the same internal boundary.
    /// Containers created directly by consumers are outside SDK ownership;
    /// callers should use ``make(path:cloudKitDatabase:)`` when possible.
    internal static func withCreationLock<T>(_ operation: () throws -> T) rethrows -> T {
        try creationLock.withLock(operation)
    }

    private static func openUnlocked(
        path: String,
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase,
        fileManager: FileManager
    ) throws -> StoreOpenResult {
        if path == ":memory:" {
            return StoreOpenResult(
                container: try ModelContainer(
                    for: schema,
                    migrationPlan: MarfaMigrationPlan.self,
                    configurations: ModelConfiguration(
                        "marfa",
                        schema: schema,
                        isStoredInMemoryOnly: true,
                        cloudKitDatabase: .none
                    )
                ),
                recovery: nil
            )
        }

        let url = URL(fileURLWithPath: path)

        // A store stamped with a version this build does not have was written
        // by a newer one, and migrating it forward would mean guessing at a
        // shape nobody has described. Refused before the open rather than
        // after it, because the open might well succeed — the hashes can still
        // match — and a build quietly writing into a newer store is the case
        // this refusal exists to prevent.
        if let newer = versionAheadOfThisBuild(at: url) {
            return try failSafe(
                url: url,
                cloudKitDatabase: cloudKitDatabase,
                cause: .newerThanCode,
                reason: newer,
                fileManager: fileManager
            )
        }

        do {
            return StoreOpenResult(
                container: try buildContainer(url: url, cloudKitDatabase: cloudKitDatabase),
                recovery: nil
            )
        } catch {
            // A store that is not there did not fail to open for a reason
            // recovery can address, and rebuilding on top of one would loop.
            // Say what actually happened instead.
            guard fileManager.fileExists(atPath: url.path) else { throw error }
            return try failSafe(
                url: url,
                cloudKitDatabase: cloudKitDatabase,
                cause: .unreadable,
                reason: error.localizedDescription,
                fileManager: fileManager
            )
        }
    }

    // MARK: - The fail-safe

    /// Moves the store aside, salvages what only it held, and builds a fresh
    /// one.
    ///
    /// The order is the design. Quarantine is a rename, which needs to know
    /// nothing about the store's contents and so cannot fail for the reason
    /// the open failed; it is therefore the only step allowed to decide
    /// whether the app starts over. Salvage runs afterwards, against a file
    /// that is already safe, and a salvage that fails costs a sidecar rather
    /// than the data.
    private static func failSafe(
        url: URL,
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase,
        cause: StoreRecovery.Cause,
        reason: String,
        fileManager: FileManager
    ) throws -> StoreOpenResult {
        let logger = Logger(subsystem: MarfaLogger.subsystem, category: "local")
        logger.error(
            "LocalStore at \(url.lastPathComponent, privacy: .public) is unusable (\(cause.rawValue, privacy: .public): \(reason, privacy: .public)); moving it aside."
        )

        // Throws on failure, and the throw is the point: no quarantine means
        // no wipe. An app that would otherwise lose its queued writes, its
        // dead letters, its cursor and its blob bytes is told instead.
        let quarantine = try StoreQuarantine.run(
            storeAt: url,
            stampedAt: Date(),
            fileManager: fileManager
        )

        var sidecarURL: URL?
        var sidecarError: String?
        var extraction = QuarantinedStoreReader.Extraction(tables: [:])
        do {
            extraction = try QuarantinedStoreReader.read(storeAt: quarantine.store)
            let sidecar = RecoveredQueueSidecar(
                cause: cause,
                reason: reason,
                storePath: url.path,
                quarantinedStorePath: quarantine.store.path,
                unmovedSiblings: quarantine.unmoved,
                recordedAt: Date(),
                extraction: extraction
            )
            let destination = quarantine.directory
                .appendingPathComponent(RecoveredQueueSidecar.fileName)
            try sidecar.write(to: destination)
            sidecarURL = destination
        } catch {
            // Best-effort by construction. The rows are still in the
            // quarantined database whether or not they could be summarized.
            sidecarError = String(describing: error)
            logger.error(
                "Could not write the recovered-queue sidecar: \(sidecarError ?? "", privacy: .public). The quarantined store still holds every row."
            )
        }

        // The journals the quarantine could not move are removed now: one
        // whose database has gone holds transactions nothing can ever replay,
        // so it costs nothing to lose and can only mislead whoever looks next.
        // Only the journals. The support directory holds the only copy of the
        // externally stored blob bytes, so removing it would reach the
        // delete-and-rebuild this path exists to replace.
        removeLeftovers(
            at: url,
            named: quarantine.removableLeftovers,
            fileManager: fileManager,
            logger: logger
        )

        // The quarantine directory has to travel with this failure. It is the
        // only record of where the queue went, it was minted inside this call,
        // and an open that returns the container's own error returns without
        // it — so the data survives and its address does not.
        let container: ModelContainer
        do {
            container = try buildContainer(url: url, cloudKitDatabase: cloudKitDatabase)
        } catch {
            logger.error(
                "LocalStore could not be rebuilt after quarantining to \(quarantine.directory.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw LocalStoreError.storeRebuildFailed(
                quarantineDirectory: quarantine.directory,
                reason: error.localizedDescription
            )
        }

        let recovery = StoreRecovery(
            cause: cause,
            reason: reason,
            quarantineDirectory: quarantine.directory,
            sidecar: sidecarURL,
            sidecarError: sidecarError,
            truncatedTables: extraction.truncated,
            pendingMutationCount: extraction.rows("pendingMutations").count,
            droppedMutationCount: extraction.rows("droppedMutations").count,
            pendingBlobCount: extraction.rows("pendingBlobs").count,
            cursor: extraction.rows("syncState")
                .first { $0["key"]?.stringValue == "last_event_id" }?["value"]?.stringValue
        )
        logger.error(
            "LocalStore rebuilt empty. Quarantine: \(quarantine.directory.lastPathComponent, privacy: .public); recovered \(recovery.pendingMutationCount, privacy: .public) queued and \(recovery.droppedMutationCount, privacy: .public) dead-lettered writes."
        )
        return StoreOpenResult(container: container, recovery: recovery)
    }

    /// Reads the store's own recorded schema version without attaching a model
    /// to it, and returns a description of the mismatch when it is ahead of
    /// this build.
    ///
    /// **This only begins telling the truth for stores written from V3
    /// onwards.** Until this change the container was handed a `Schema` built
    /// from a model array rather than from a versioned schema, so the version
    /// identifier never reached disk and every store on disk records `1.0.0`,
    /// V2 stores included — established by reading a committed store's own
    /// metadata rather than from the code. Fixing that stamps the version from
    /// here on, which means the first comparison this check can actually make
    /// is against the version after V3.
    private static func versionAheadOfThisBuild(at url: URL) -> String? {
        guard let recorded = recordedVersion(at: url) else { return nil }
        let current = MarfaMigrationPlan.current.versionIdentifier
        guard recorded > current else { return nil }
        return "the store records schema version \(recorded), and this build knows up to \(current)"
    }

    private static func recordedVersion(at url: URL) -> Schema.Version? {
        // A metadata read rather than a compatibility-checked open, so it
        // answers for a store this build's schema would refuse.
        guard
            let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
                type: .sqlite, at: url, options: nil
            ),
            let identifiers = metadata[NSStoreModelVersionIdentifiersKey] as? [Any],
            let stamp = identifiers.compactMap({ $0 as? String }).first
        else { return nil }
        let parts = stamp.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Schema.Version(parts[0], parts[1], parts[2])
    }

    // MARK: - Construction

    /// The schema this build opens stores under, built from the versioned
    /// schema rather than from a bare model list so the version identifier
    /// reaches the file.
    private static var schema: Schema {
        Schema(versionedSchema: MarfaMigrationPlan.current)
    }

    private static func buildContainer(
        url: URL,
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase
    ) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            migrationPlan: MarfaMigrationPlan.self,
            configurations: ModelConfiguration(
                "marfa",
                schema: schema,
                url: url,
                allowsSave: true,
                cloudKitDatabase: cloudKitDatabase
            )
        )
    }

    /// Removes the named siblings still sitting beside a store that has moved.
    ///
    /// Reported rather than swallowed. The previous version of this path
    /// discarded its own diagnostic with a `try?`, so the one step capable of
    /// destroying a person's queued work was also the one step that never said
    /// anything.
    private static func removeLeftovers(
        at url: URL,
        named siblings: [String],
        fileManager: FileManager,
        logger: Logger
    ) {
        let parent = url.deletingLastPathComponent()
        for sibling in siblings {
            let leftover = parent.appendingPathComponent(sibling)
            do {
                try fileManager.removeItem(at: leftover)
            } catch {
                logger.error(
                    "Could not remove \(sibling, privacy: .public) left beside the rebuilt store: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
