#if os(macOS)
import Foundation
import MarfaCore
import Synchronization

/// The folders on this Mac: directories whose files Marfa keeps in step with a folder's settings on the server.
///
/// Folders work through the same core as the `marfa` command-line tool, and the Mac keeps one registry of
/// them, so a folder added here appears in `marfa folders list`, and one added there appears in `list()`.
///
/// One process works a folder at a time. While the command-line tool or a watch holds a folder, `sync(_:)`,
/// `confirmRemoval(in:)`, `restoreRemoval(in:)`, `remove(_:)` and `watch(_:)` throw `MarfaError.readingHandle`;
/// `status(of:)` still answers. Every call runs off the caller's thread.
public struct Folders: Sendable {
    /// The server that `add(_:following:)`, `sync(_:)`, `restoreRemoval(in:)` and `watch(_:)` reach.
    public let server: Server?

    /// Without a server, only `list()`, `status(of:)`, `confirmRemoval(in:)` and `remove(_:)` work.
    public init(server: Server? = nil) {
        self.server = server
    }

    /// Makes a directory a folder that follows the settings of the `system.folder` item `folderId`, and lists
    /// it in the Mac's registry.
    ///
    /// The directory is made if it isn't there. Its files are sent and written at the first sync.
    public func add(_ directory: URL, following folderId: String) async throws -> ListedFolder {
        let dir = directory.path(percentEncoded: false)
        return ListedFolder(try await run { folders in try folders.add(dir: dir, folder: folderId) })
    }

    /// The folders the Mac's registry lists, including those the command-line tool added.
    public func list() async throws -> [ListedFolder] {
        try await run { folders in try folders.list().map(ListedFolder.init) }
    }

    /// Where every file in the folder stands, read from the folder's own store without asking the server.
    public func status(of directory: URL) async throws -> FolderStatus {
        let dir = directory.path(percentEncoded: false)
        return FolderStatus(try await run { folders in try folders.status(dir: dir) })
    }

    /// Syncs the folder once: sends what changed on disk, catches up with the server, and writes out what the
    /// folder's search matches.
    ///
    /// When the server can't be reached, the sync still writes out the copy it holds, and `catchUpError` says
    /// why it couldn't catch up.
    public func sync(_ directory: URL) async throws -> FolderSync {
        let dir = directory.path(percentEncoded: false)
        return FolderSync(try await run { folders in try folders.sync(dir: dir) })
    }

    /// Lets a paused large removal go: its deletes are queued for the next sync, and files whose items left
    /// elsewhere are removed.
    public func confirmRemoval(in directory: URL) async throws -> ConfirmedRemoval {
        let dir = directory.path(percentEncoded: false)
        return ConfirmedRemoval(try await run { folders in try folders.confirm(dir: dir) })
    }

    /// Cancels a paused large removal: files gone from the disk are written back, and items that left elsewhere
    /// are restored at the next sync.
    public func restoreRemoval(in directory: URL) async throws -> RestoredRemoval {
        let dir = directory.path(percentEncoded: false)
        return RestoredRemoval(try await run { folders in try folders.restore(dir: dir) })
    }

    /// Takes the folder off this Mac, and leaves its files as plain files.
    ///
    /// Throws `MarfaError.invalid` while writes wait to be sent; sync first. A folder whose directory is gone is
    /// only taken off the registry.
    public func remove(_ directory: URL) async throws {
        let dir = directory.path(percentEncoded: false)
        try await run { folders in try folders.remove(dir: dir) }
    }

    /// Starts keeping the folder in step while the app runs, as `marfa folders watch` does.
    ///
    /// Throws at once when the folder can't be opened, such as when another process holds it. Once started,
    /// the watch holds the folder until it ends.
    public func watch(_ directory: URL) async throws -> FolderWatch {
        let dir = directory.path(percentEncoded: false)
        let (events, continuation) = AsyncThrowingStream<FolderEvent, any Error>.makeStream()
        let ending = FolderWatch.Ending()
        let relay = FolderRelay(continuation: continuation, ending: ending)
        let subscription = try await run { folders in try folders.watch(dir: dir, listener: relay) }
        continuation.onTermination = { [weak subscription] _ in subscription?.stop() }
        return FolderWatch(events: events, subscription: subscription, ending: ending)
    }

    private func run<T: Sendable>(_ work: @escaping @Sendable (MarfaCore.Folders) throws -> T) async throws -> T {
        let url = server?.url.absoluteString
        let key = server?.key
        return try await background { try work(MarfaCore.Folders(url: url, key: key)) }
    }
}

/// A folder kept in step while the app runs.
///
/// Iterate it for what the watch does. The sequence ends after `stop()`, and throws a `MarfaError` when the
/// watch fails: when the server refuses the credential (`unauthorized`), when the server's changes stop
/// reaching the folder, or when the directory can't be watched. Ending the task that iterates it stops the
/// watch, and so does releasing it while nothing iterates it.
public final class FolderWatch: AsyncSequence, Sendable {
    public typealias Element = FolderEvent

    private let events: AsyncThrowingStream<FolderEvent, any Error>
    private let subscription: MarfaCore.Subscription
    private let ending: Ending

    fileprivate init(
        events: AsyncThrowingStream<FolderEvent, any Error>, subscription: MarfaCore.Subscription, ending: Ending
    ) {
        self.events = events
        self.subscription = subscription
        self.ending = ending
    }

    /// Stops the watch, and returns once it has let go of the folder.
    ///
    /// A pass under way finishes first.
    public func stop() async {
        subscription.stop()
        await ending.wait()
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator(), watch: self)
    }

    public struct Iterator: AsyncIteratorProtocol {
        var events: AsyncThrowingStream<FolderEvent, any Error>.AsyncIterator
        // Keeps the watch running for as long as it is iterated.
        let watch: FolderWatch

        public mutating func next() async throws -> FolderEvent? {
            try await events.next()
        }
    }

    final class Ending: Sendable {
        private struct State {
            var ended = false
            var waiting: [CheckedContinuation<Void, Never>] = []
        }

        private let state = Mutex(State())

        func end() {
            let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.ended = true
                defer { state.waiting = [] }
                return state.waiting
            }
            for continuation in waiting { continuation.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let ended = state.withLock { state -> Bool in
                    if !state.ended { state.waiting.append(continuation) }
                    return state.ended
                }
                if ended { continuation.resume() }
            }
        }
    }
}

/// The core calls it on a thread of its own, and holds it until `ended` returns.
private final class FolderRelay: MarfaCore.FolderListener, Sendable {
    let continuation: AsyncThrowingStream<FolderEvent, any Error>.Continuation
    let ending: FolderWatch.Ending

    init(continuation: AsyncThrowingStream<FolderEvent, any Error>.Continuation, ending: FolderWatch.Ending) {
        self.continuation = continuation
        self.ending = ending
    }

    func told(event: MarfaCore.FolderEvent) {
        continuation.yield(FolderEvent(event))
    }

    func ended(error: MarfaCore.MarfaError?) {
        if let error {
            continuation.finish(throwing: MarfaError(error))
        } else {
            continuation.finish()
        }
        ending.end()
    }
}

/// What a watch does, each when it happens.
public enum FolderEvent: Sendable, Hashable {
    /// The watch is watching the directory, and its passes begin.
    case watching(URL)
    /// The file system reported an error; the watch goes on.
    case watcherFailed(message: String)
    /// Hydrating the folder failed, and the watch tries again after the wait. Reported once for each run of
    /// failures.
    case retrying(MarfaError, after: Duration)
    /// The server can't be reached, and writes wait. Reported when it changes.
    case unreachable(reason: String)
    /// The server answers again. Reported when it changes.
    case reachable
    /// The folder's directory is gone, and the watch waits for it to come back. Reported once.
    case waiting(reason: String)
    /// A pass that changed something, or found something new to report.
    case passed(FolderPass)

    init(_ core: MarfaCore.FolderEvent) {
        switch core {
        case .watching(let dir): self = .watching(URL(filePath: dir, directoryHint: .isDirectory))
        case .watcherFailed(let message): self = .watcherFailed(message: message)
        case .retrying(let error, let waitMs): self = .retrying(MarfaError(error), after: .milliseconds(waitMs))
        case .unreachable(let reason): self = .unreachable(reason: reason)
        case .reachable: self = .reachable
        case .waiting(let reason): self = .waiting(reason: reason)
        case .passed(let pass): self = .passed(FolderPass(pass))
        }
    }
}

/// A folder as the Mac's registry lists it.
public struct ListedFolder: Sendable, Hashable {
    /// The directory, with symbolic links resolved as far as it exists.
    public var directory: URL
    /// The id of the `system.folder` item whose settings the folder follows.
    public var folderId: String

    public init(directory: URL, folderId: String) {
        self.directory = directory
        self.folderId = folderId
    }

    init(_ core: MarfaCore.ListedFolder) {
        self.init(directory: URL(filePath: core.dir, directoryHint: .isDirectory), folderId: core.folder)
    }
}

/// Where every file in a folder stands.
public struct FolderStatus: Sendable, Hashable {
    public var files: [FileStatus]
    /// A large removal waiting for `confirmRemoval(in:)` or `restoreRemoval(in:)`.
    public var paused: PausedRemoval

    public init(files: [FileStatus], paused: PausedRemoval = PausedRemoval()) {
        self.files = files
        self.paused = paused
    }

    init(_ core: MarfaCore.FolderStatus) {
        self.init(files: core.files.map(FileStatus.init), paused: PausedRemoval(core.paused))
    }
}

public struct FileStatus: Sendable, Hashable {
    /// The file's path inside the folder.
    public var path: String
    public var itemId: String?
    public var state: FileState
    /// For a waiting file, the kinds of write that wait, such as `create` or `edit`.
    public var waits: [String]
    public var flag: String?
    /// Why the file is held or waits.
    public var reason: String?
    public var warning: String?

    public init(
        path: String, itemId: String? = nil, state: FileState, waits: [String] = [], flag: String? = nil,
        reason: String? = nil, warning: String? = nil
    ) {
        self.path = path
        self.itemId = itemId
        self.state = state
        self.waits = waits
        self.flag = flag
        self.reason = reason
        self.warning = warning
    }

    init(_ core: MarfaCore.FileStatus) {
        self.init(
            path: core.path, itemId: core.itemId, state: FileState(core.state), waits: core.waits, flag: core.flag,
            reason: core.reason, warning: core.warning)
    }
}

public enum FileState: Sendable, Hashable {
    /// The file and its item agree.
    case inStep
    /// A write for the file waits to be sent.
    case waiting
    /// The file isn't sent; its status says why.
    case held
    /// The file's item no longer matches the folder's search.
    case unmatched
    /// The scan didn't reach the file, so it's held rather than deleted.
    case unreached
    /// The file lies where the folder doesn't take files.
    case outside

    init(_ core: MarfaCore.FileState) {
        switch core {
        case .inStep: self = .inStep
        case .waiting: self = .waiting
        case .held: self = .held
        case .unmatched: self = .unmatched
        case .unreached: self = .unreached
        case .outside: self = .outside
        }
    }
}

/// A large removal that waits for the person to confirm or cancel it.
public struct PausedRemoval: Sendable, Hashable {
    /// Files gone from the disk whose deletes aren't sent.
    public var disk: UInt64
    /// Files left in place whose items left the folder's search elsewhere.
    public var pull: UInt64

    /// Whether a removal waits.
    public var isPaused: Bool { disk + pull > 0 }

    public init(disk: UInt64 = 0, pull: UInt64 = 0) {
        self.disk = disk
        self.pull = pull
    }

    init(_ core: MarfaCore.PausedRemoval) {
        self.init(disk: core.disk, pull: core.pull)
    }
}

/// What one sync did.
public struct FolderSync: Sendable, Hashable {
    /// The hydration the sync ran first, where the folder's copy didn't hold what its settings ask for.
    public let hydrated: HydrateReport?
    /// Why the sync couldn't catch up with the server, where it couldn't.
    public let catchUpError: MarfaError?
    public let pass: FolderPass

    init(_ core: MarfaCore.FolderSync) {
        hydrated = core.hydrated.map(HydrateReport.init)
        catchUpError = core.catchUpError.map(MarfaError.init)
        pass = FolderPass(core.pass)
    }
}

/// One pass over a folder: the settings file's edit, the scan, the drain and the pull.
public struct FolderPass: Sendable, Hashable {
    public let settings: SettingsFileOutcome
    public let scan: FolderScan
    public let drain: DrainReport
    /// Edits written from a version the server no longer holds, sent again on the version the copy holds.
    public let rebased: UInt64
    /// Placements another Mac made first, followed instead.
    public let gaveWay: UInt64
    /// `nil` where the copy expired and couldn't be hydrated, so there was nothing to write out.
    public let pull: FolderPull?
    /// The files the pass held, each with why.
    public let flagged: [FlaggedFile]

    init(_ core: MarfaCore.FolderPass) {
        settings = SettingsFileOutcome(core.settings)
        scan = FolderScan(core.scan)
        drain = DrainReport(core.drain)
        rebased = core.rebased
        gaveWay = core.gaveWay
        pull = core.pull.map(FolderPull.init)
        flagged = core.flagged.map(FlaggedFile.init)
    }
}

/// What became of the folder's settings file in a pass.
public struct SettingsFileOutcome: Sendable, Hashable {
    /// The file's edit went to the server.
    public let sent: Bool
    /// The file was written from the settings in force.
    public let written: Bool
    /// Why the file's edit isn't in force.
    public let flagged: String?
    /// Why the file couldn't be written; the next pass writes it.
    public let unwritten: String?

    init(_ core: MarfaCore.SettingsFileOutcome) {
        sent = core.sent
        written = core.written
        flagged = core.flagged
        unwritten = core.unwritten
    }
}

/// What a pass read from the disk.
public struct FolderScan: Sendable, Hashable {
    public let created: UInt64
    public let updated: UInt64
    public let renamed: UInt64
    public let unchanged: UInt64
    public let missing: UInt64
    public let deleted: UInt64
    public let skipped: UInt64
    /// Files moved to another folder on this Mac, so nothing was deleted.
    public let movedAway: UInt64
    /// Deletes a large removal holds back.
    public let paused: UInt64
    /// Files found in no folder on this Mac, whose items were moved to the bin.
    public let trashed: [String]
    /// Files not sent because their names are ones that secrets use.
    public let secrets: [String]
    public let warnings: [FlaggedFile]
    /// Why the scan read nothing, where the folder's directory is gone.
    public let rootGone: String?

    init(_ core: MarfaCore.FolderScan) {
        created = core.created
        updated = core.updated
        renamed = core.renamed
        unchanged = core.unchanged
        missing = core.missing
        deleted = core.deleted
        skipped = core.skipped
        movedAway = core.movedAway
        paused = core.paused
        trashed = core.trashed
        secrets = core.secrets
        warnings = core.warnings.map(FlaggedFile.init)
        rootGone = core.rootGone
    }
}

/// What a pass wrote to the disk.
public struct FolderPull: Sendable, Hashable {
    public let written: UInt64
    public let rewritten: UInt64
    public let moved: UInt64
    public let unchanged: UInt64
    public let skipped: UInt64
    /// Files of items moved to the bin or out of the search's states, removed.
    public let removed: UInt64
    /// Files of items gone from the search, kept because the person changed them.
    public let kept: UInt64
    /// Files the folder didn't write, and won't write over.
    public let unwritten: UInt64
    /// Items whose bytes couldn't be fetched.
    public let absent: UInt64
    /// Placements the server refused.
    public let unplaced: UInt64
    /// Files left in place whose items the search no longer matches.
    public let unmatched: UInt64
    /// Files a large removal holds back.
    public let paused: UInt64
    /// Why the pull wrote nothing, where the folder's directory is gone.
    public let rootGone: String?

    init(_ core: MarfaCore.FolderPull) {
        written = core.written
        rewritten = core.rewritten
        moved = core.moved
        unchanged = core.unchanged
        skipped = core.skipped
        removed = core.removed
        kept = core.kept
        unwritten = core.unwritten
        absent = core.absent
        unplaced = core.unplaced
        unmatched = core.unmatched
        paused = core.paused
        rootGone = core.rootGone
    }
}

/// A file a pass held or warned about.
public struct FlaggedFile: Sendable, Hashable {
    public let path: String
    public let flag: String
    public let reason: String

    init(_ core: MarfaCore.FlaggedFile) {
        path = core.path
        flag = core.flag
        reason = core.reason
    }
}

/// What confirming a paused removal did.
public struct ConfirmedRemoval: Sendable, Hashable {
    /// Deletes queued for the next sync.
    public let deleted: UInt64
    /// Files found in another folder on this Mac, whose items stay.
    public let moved: UInt64
    /// Files removed whose items left elsewhere.
    public let removed: UInt64
    /// Files not let go, because the other folders couldn't all be read.
    public let unsure: [UnsureFile]

    init(_ core: MarfaCore.ConfirmedRemoval) {
        deleted = core.deleted
        moved = core.moved
        removed = core.removed
        unsure = core.unsure.map(UnsureFile.init)
    }
}

public struct UnsureFile: Sendable, Hashable {
    public let path: String
    public let reason: String

    init(_ core: MarfaCore.UnsureFile) {
        path = core.path
        reason = core.reason
    }
}

/// What cancelling a paused removal did.
public struct RestoredRemoval: Sendable, Hashable {
    /// Files gone from the disk, written back.
    public let putBack: UInt64
    /// Items that left elsewhere, restored at the next sync.
    public let restored: UInt64
    public let pull: FolderPull

    init(_ core: MarfaCore.RestoredRemoval) {
        putBack = core.putBack
        restored = core.restored
        pull = FolderPull(core.pull)
    }
}
#endif
