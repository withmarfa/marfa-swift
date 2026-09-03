import Foundation

/// Moves a store the running build cannot open out of the way, intact.
///
/// **A rename is the whole design.** The store refused to open for a reason
/// that lives in its contents — a shape this build has no model for — and
/// every recovery step that has to read those contents can fail for the same
/// reason. `rename(2)` cannot: it moves a directory entry and never looks
/// inside the file. So the move goes first, it is the one step allowed to
/// decide whether the store is destroyed, and everything after it works
/// against a copy that is already safe.
///
/// That inverts the previous arrangement, where the store was deleted first
/// and salvage was not attempted at all.
enum StoreQuarantine {

    /// What the move achieved.
    struct Outcome {
        /// The directory everything was moved into.
        let directory: URL

        /// The store file inside it.
        let store: URL

        /// Names still sitting beside the original store because the move
        /// would not take them. Empty on the ordinary path. A name here is
        /// data that stayed where it was, and it is reported so the sidecar
        /// can say where to look for it.
        let unmoved: [String]

        /// The subset of ``unmoved`` the caller may delete.
        ///
        /// The journals, and only the journals. A journal whose database has
        /// gone holds transactions nothing can ever replay, so removing it
        /// costs nothing and leaving it beside the store that replaces it can
        /// only mislead whoever looks next. **The support directory is not
        /// like that in either direction.** It holds the only copy of the
        /// externally stored bytes, which for this schema is the payload of
        /// every queued blob upload, and the store that replaces it neither
        /// reads what is in there nor collides with it — Core Data names each
        /// external file with a fresh UUID. Deleting it would reach the same
        /// end state as the delete-and-rebuild this whole path replaces, by
        /// the one route written to prevent it.
        var removableLeftovers: [String] {
            let support = StoreQuarantine.supportDirectoryName(of: store)
            return unmoved.filter { $0 != support }
        }
    }

    /// The journals SQLite keeps beside a store file, relative to its name.
    static func journalNames(of store: URL) -> [String] {
        let name = store.lastPathComponent
        return ["\(name)-wal", "\(name)-shm", "\(name)-journal"]
    }

    /// The support directory Core Data keeps beside a store file.
    ///
    /// It holds externally-stored attribute bytes — the queued blob uploads,
    /// in this schema — so a quarantine that left it behind would preserve the
    /// rows and lose what they point at.
    static func supportDirectoryName(of store: URL) -> String {
        ".\(store.deletingPathExtension().lastPathComponent)_SUPPORT"
    }

    /// Everything SQLite and Core Data keep beside a store file.
    static func siblingNames(of store: URL) -> [String] {
        journalNames(of: store) + [supportDirectoryName(of: store)]
    }

    /// Moves `store` and everything beside it into a fresh directory alongside.
    ///
    /// - Throws: ``LocalStoreError/storeQuarantineFailed(_:)`` when the store
    ///   file itself could not be moved. The caller must not delete anything
    ///   in that case — a store that cannot be set aside is a store that must
    ///   be left alone.
    static func run(
        storeAt store: URL,
        stampedAt timestamp: Date,
        fileManager: FileManager = .default
    ) throws -> Outcome {
        let directory: URL
        do {
            directory = try makeDirectory(beside: store, at: timestamp, fileManager: fileManager)
        } catch {
            throw LocalStoreError.storeQuarantineFailed(
                "could not create a quarantine directory beside \(store.lastPathComponent): "
                    + error.localizedDescription
            )
        }

        let quarantinedStore = directory.appendingPathComponent(store.lastPathComponent)
        do {
            try fileManager.moveItem(at: store, to: quarantinedStore)
        } catch {
            // Nothing has been destroyed and nothing will be: the caller
            // rethrows and the store stays exactly where it was.
            try? fileManager.removeItem(at: directory)
            throw LocalStoreError.storeQuarantineFailed(
                "could not move \(store.lastPathComponent) aside: \(error.localizedDescription)"
            )
        }

        // Best-effort from here. The database is safe; a journal that will not
        // move costs the last few transactions it holds, and the alternative —
        // refusing the whole recovery — costs the app its store for good.
        var unmoved: [String] = []
        for sibling in siblingNames(of: store) {
            let source = store.deletingLastPathComponent().appendingPathComponent(sibling)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            do {
                try fileManager.moveItem(at: source, to: directory.appendingPathComponent(sibling))
            } catch {
                unmoved.append(sibling)
            }
        }

        return Outcome(directory: directory, store: quarantinedStore, unmoved: unmoved)
    }

    /// Creates the directory the store moves into, refusing to reuse one.
    ///
    /// `withIntermediateDirectories: false` is the load-bearing flag: it makes
    /// the create fail rather than succeed against a directory that is already
    /// there, so a second incident in the same second gets its own directory
    /// instead of moving a store on top of the last one's.
    private static func makeDirectory(
        beside store: URL,
        at timestamp: Date,
        fileManager: FileManager
    ) throws -> URL {
        let parent = store.deletingLastPathComponent()
        let base = "\(store.lastPathComponent).quarantined-\(stamp(timestamp))"
        var lastError: Error?
        for attempt in 0..<64 {
            let name = attempt == 0 ? base : "\(base)-\(attempt + 1)"
            let candidate = parent.appendingPathComponent(name, isDirectory: true)
            do {
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate
            } catch {
                lastError = error
            }
        }
        throw lastError ?? LocalStoreError.storeQuarantineFailed("no free quarantine directory name")
    }

    /// `20260903T101112Z` — seconds resolution, UTC, no separators. A device
    /// that meets this twice keeps both directories, because a second incident
    /// is not evidence that the first was dealt with.
    private static func stamp(_ timestamp: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: timestamp)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}
