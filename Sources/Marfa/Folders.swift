#if os(macOS)
import Foundation
import MarfaCore
import Synchronization

/// The folders on this Mac: directories whose files Marfa keeps in step with a folder's settings on the server.
///
/// Folders work through the same core and the same registry as the `marfa` command-line tool, so a folder
/// added here appears in `marfa folders list`, and one added there appears in `list()`.
///
/// A new folder's first sync waits for the person to confirm it: `sync(_:)` reads the folder and returns
/// ``FolderSyncResult/awaitingConfirmation(_:)`` with what the sync will do, and nothing is written into the
/// directory or sent until `confirmFirstSync(in:)`. `remove(_:)` cancels it and leaves the files.
///
/// One process works a folder at a time. While the command-line tool or a watch holds a folder, `sync(_:)`,
/// `confirmFirstSync(in:)`, `confirmRemoval(in:)`, `restoreRemoval(in:)`, `remove(_:)` and `watch(_:)` throw
/// `MarfaError.readingHandle`; `status(of:)` still answers. Every call runs off the caller's thread.
public struct Folders: Sendable {
    /// The server that `add(_:following:)`, `sync(_:)`, `restoreRemoval(in:)` and `watch(_:)` reach.
    public let server: Server?

    /// Creates a value that works the Mac's folders, reaching `server` where one is given.
    ///
    /// Without a server, only `list()`, `status(of:)`, `confirmFirstSync(in:)`, `confirmRemoval(in:)`,
    /// `restoreRemoval(in:)` and `remove(_:)` work.
    public init(server: Server? = nil) {
        self.server = server
    }

    /// Makes a directory a folder that follows the settings of the `system.folder` item `folderId`, and lists
    /// it in the Mac's registry.
    ///
    /// The directory is made if it isn't there. Its first sync waits: `sync(_:)` says what it will do, and
    /// `confirmFirstSync(in:)` lets it go.
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

    /// Syncs the folder once: sends what changed on disk, catches up with the server, writes out what the
    /// folder's search matches, and sends the placements of the files it wrote.
    ///
    /// While the folder's first sync waits to be confirmed, it only reads the folder and returns
    /// ``FolderSyncResult/awaitingConfirmation(_:)``: nothing was written or sent.
    ///
    /// When the server can't be reached, the sync still writes out the copy it holds, and `catchUpError` says
    /// why it couldn't catch up.
    public func sync(_ directory: URL) async throws -> FolderSyncResult {
        let dir = directory.path(percentEncoded: false)
        return FolderSyncResult(try await run { folders in try folders.sync(dir: dir) })
    }

    /// Lets the folder's first sync go.
    ///
    /// The next `sync(_:)` or `watch(_:)` runs it. Returns whether it was waiting. Asks nothing of the server.
    @discardableResult
    public func confirmFirstSync(in directory: URL) async throws -> Bool {
        let dir = directory.path(percentEncoded: false)
        return try await run { folders in try folders.confirmFirstSync(dir: dir) }
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
    /// On a folder whose first sync waits, it cancels that sync.
    ///
    /// Throws `MarfaError.invalid` while writes wait to be sent; sync first. A folder whose directory is gone is
    /// only taken off the registry.
    public func remove(_ directory: URL) async throws {
        let dir = directory.path(percentEncoded: false)
        try await run { folders in try folders.remove(dir: dir) }
    }

    /// Starts keeping the folder in step while the app runs, as `marfa folders watch` does.
    ///
    /// Throws at once when the folder can't be opened, such as when another process holds it, and throws
    /// `MarfaError.firstSyncWaiting` while the folder's first sync waits to be confirmed. Once started, the
    /// watch holds the folder until it ends.
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
/// reaching the folder, or when the directory can't be watched. Cancelling the task that iterates it stops
/// the watch, and so does releasing it while nothing iterates it; leaving a loop over it early doesn't, so
/// call `stop()`.
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
    /// Set while the folder's first sync waits for `confirmFirstSync(in:)`.
    public var firstSync: WaitingFirstSync?

    public init(files: [FileStatus], paused: PausedRemoval = PausedRemoval(), firstSync: WaitingFirstSync? = nil) {
        self.files = files
        self.paused = paused
        self.firstSync = firstSync
    }

    init(_ core: MarfaCore.FolderStatus) {
        self.init(
            files: core.files.map(FileStatus.init), paused: PausedRemoval(core.paused),
            firstSync: core.firstSync.map(WaitingFirstSync.init))
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

/// What a sync came to.
public enum FolderSyncResult: Sendable, Hashable {
    /// The sync ran.
    case synced(FolderSync)
    /// The folder's first sync waits for `confirmFirstSync(in:)`, so nothing was written or sent.
    case awaitingConfirmation(FirstSyncPlan)

    init(_ core: MarfaCore.FolderSyncOutcome) {
        switch core {
        case .done(let sync): self = .synced(FolderSync(sync))
        case .waiting(let plan): self = .awaitingConfirmation(FirstSyncPlan(plan))
        }
    }
}

/// What a folder's first sync will do, read from the folder as it stands.
public struct FirstSyncPlan: Sendable, Hashable {
    /// Files it will write into the directory.
    public let write: UInt64
    /// Files in the directory it will send, as new items or as the edits of the items they name.
    public let send: UInt64
    /// How many of the files it will write take a path a file already in the directory has.
    ///
    /// Both end up in the folder, one of the two with a number in its name, and none is written over.
    public let beside: UInt64

    public init(write: UInt64, send: UInt64, beside: UInt64) {
        self.write = write
        self.send = send
        self.beside = beside
    }

    init(_ core: MarfaCore.FirstSyncPlan) {
        write = core.write
        send = core.send
        beside = core.beside
    }
}

/// A first sync that waits for the person's go-ahead.
public struct WaitingFirstSync: Sendable, Hashable {
    /// What the last read of the folder said it will do, and `nil` until `sync(_:)` has read it.
    public let plan: FirstSyncPlan?

    public init(plan: FirstSyncPlan? = nil) {
        self.plan = plan
    }

    init(_ core: MarfaCore.WaitingFirstSync) {
        plan = core.plan.map(FirstSyncPlan.init)
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
    /// The writes the pass sent.
    ///
    /// A sync drains again after its pull, so this also counts the placements of the files the pull wrote; where
    /// the first drain or the catch-up showed the server can't take writes, it doesn't, and those placements wait
    /// for the next sync.
    ///
    /// A conflicted edit is a verdict of `.conflicted` naming the item and the copy that took its text. The drain
    /// answers every write the folder's store holds, so a verdict can be for an item that isn't a file of this
    /// folder.
    public let drain: DrainReport
    /// Edits written from a version the server no longer holds, sent again on the version the copy holds.
    public let rebased: UInt64
    /// Placements another Mac made first, followed instead.
    public let gaveWay: UInt64
    /// `nil` where the copy expired and couldn't be hydrated, so there was nothing to write out.
    public let pull: FolderPull?
    /// The files the scan and the pull held, each with why and each once.
    ///
    /// The pull's entries name their item.
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
    /// Files of items moved to the bin, purged, or moved out of the search's states, removed.
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
    /// The id of the item a pull held back, where a pull did.
    ///
    /// Set for a `flag` of `unwritten`, `outside`, `unsuited` or `absent`, where the pull didn't write the item's
    /// file, and `retained`, for a file the pull couldn't let go to another folder. Then `path` is where the pull
    /// would have written the file, or the item's own file where it left that file as it stands. `nil` for a file
    /// the scan flagged. Two items held back at one path are two entries.
    public let item: String?

    init(_ core: MarfaCore.FlaggedFile) {
        path = core.path
        flag = core.flag
        reason = core.reason
        item = core.item
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
