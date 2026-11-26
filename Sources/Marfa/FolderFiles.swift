#if os(macOS)
import Foundation
internal import MarfaCore

/// The local folder operations that manage unmatched, kept and held files, and the directories folders remember.
public protocol FolderFileManaging: Sendable {
    func removeUnmatched(in directory: URL, paths: [String]) async throws -> UnmatchedRemoved
    func keptFiles(in directory: URL) async throws -> [KeptFile]
    func discardKept(in directory: URL) async throws -> KeptDiscarded
    func heldFiles(in directory: URL) async throws -> [HeldFile]
    func trashHeld(in directory: URL, paths: [String]) async throws -> SettledHeld
    func keepHeld(in directory: URL, paths: [String], writeBack: Bool) async throws -> SettledHeld
    func remembering(_ directory: URL) async throws -> Remembered
    func forget(_ remembered: Remembered) async throws -> Forgotten
}

/// The outcome for each requested path and the number of placements ended.
public struct UnmatchedRemoved: Sendable, Hashable {
    public let removed: [UnmatchedFile]
    public let kept: [KeptUnmatched]
    public let ended: UInt64

    public init(removed: [UnmatchedFile], kept: [KeptUnmatched], ended: UInt64) {
        self.removed = removed
        self.kept = kept
        self.ended = ended
    }

    init(_ core: MarfaCore.UnmatchedRemoved) {
        self.init(
            removed: core.removed.map(UnmatchedFile.init), kept: core.kept.map(KeptUnmatched.init), ended: core.ended)
    }
}

/// An unmatched file removed from the directory.
public struct UnmatchedFile: Sendable, Hashable {
    public let path: String
    public let itemId: String?

    public init(path: String, itemId: String?) {
        self.path = path
        self.itemId = itemId
    }

    init(_ core: MarfaCore.UnmatchedFile) {
        self.init(path: core.path, itemId: core.itemId)
    }
}

/// A requested path the folder kept and why.
public struct KeptUnmatched: Sendable, Hashable {
    public let path: String
    public let itemId: String?
    public let reason: String

    public init(path: String, itemId: String?, reason: String) {
        self.path = path
        self.itemId = itemId
        self.reason = reason
    }

    init(_ core: MarfaCore.KeptUnmatched) {
        self.init(path: core.path, itemId: core.itemId, reason: core.reason)
    }
}

/// A file Marfa set aside because another program might write to it.
public struct KeptFile: Sendable, Hashable {
    /// Its reserved path inside the folder.
    public let path: String
    /// The original path inside the folder.
    public let from: String
    public let writers: KeptWriters
    /// The UTC discard date as `YYYY-MM-DD`, when set.
    public let until: String?
    public let reason: String

    public init(path: String, from: String, writers: KeptWriters, until: String?, reason: String) {
        self.path = path
        self.from = from
        self.writers = writers
        self.until = until
        self.reason = reason
    }

    init(_ core: MarfaCore.KeptFile) {
        self.init(
            path: core.path, from: core.from, writers: KeptWriters(core.writers), until: core.until, reason: core.reason
        )
    }
}

/// The outcome of discarding kept files.
public struct KeptDiscarded: Sendable, Hashable {
    public let discarded: [String]
    /// The paths of changed files returned to the directory.
    public let putBack: [String]
    public let kept: [KeptFile]

    public init(discarded: [String], putBack: [String], kept: [KeptFile]) {
        self.discarded = discarded
        self.putBack = putBack
        self.kept = kept
    }

    init(_ core: MarfaCore.KeptDiscarded) {
        self.init(discarded: core.discarded, putBack: core.putBack, kept: core.kept.map(KeptFile.init))
    }
}

/// A missing file whose delete the folder holds, because Marfa can't tell whether the person deleted it or moved
/// it into another folder.
///
/// To settle the hold, call ``FolderFileManaging/trashHeld(in:paths:)`` or
/// ``FolderFileManaging/keepHeld(in:paths:writeBack:)``. If the file waits on a directory that is gone for good,
/// ``FolderFileManaging/remembering(_:)`` shows whether forgetting that directory would release it.
public struct HeldFile: Sendable, Hashable {
    /// The file's path inside the folder.
    public let path: String
    /// The id of the item the file stood for.
    public let item: String
    /// When the folder first found the file missing, as the core reports it.
    public let missingSince: String
    /// Why the delete is held, in the core's words.
    ///
    /// It may name the other folders the file could be in.
    public let reason: String

    public init(path: String, item: String, missingSince: String, reason: String) {
        self.path = path
        self.item = item
        self.missingSince = missingSince
        self.reason = reason
    }

    init(_ core: MarfaCore.HeldFile) {
        self.init(path: core.path, item: core.item, missingSince: core.missingSince, reason: core.reason)
    }
}

/// What settling held files did, for each file the call named.
///
/// Before reporting that a delete is queued, check both ``trashed`` and ``notSettled`` for its path.
/// A path can occur more than once when multiple items were held there.
public struct SettledHeld: Sendable, Hashable {
    /// Files whose items' deletes are queued, sent at the next sync.
    public let trashed: [String]
    /// Files whose items were already in the bin or gone.
    public let gone: [String]
    /// Files one other readable folder now holds, whose items stay.
    public let moved: [String]
    /// Files whose items stay, and which the folder lets go.
    public let kept: [String]
    /// Kept files written again.
    public let writtenBack: [String]
    /// Kept files not written again, each with why.
    public let notWrittenBack: [FlaggedFile]
    /// Named files left as they were, each with why.
    ///
    /// Any existing hold remains.
    public let notSettled: [UnsureFile]

    public init(
        trashed: [String] = [], gone: [String] = [], moved: [String] = [], kept: [String] = [],
        writtenBack: [String] = [], notWrittenBack: [FlaggedFile] = [], notSettled: [UnsureFile] = []
    ) {
        self.trashed = trashed
        self.gone = gone
        self.moved = moved
        self.kept = kept
        self.writtenBack = writtenBack
        self.notWrittenBack = notWrittenBack
        self.notSettled = notSettled
    }

    init(_ core: MarfaCore.SettledHeld) {
        self.init(
            trashed: core.trashed, gone: core.gone, moved: core.moved, kept: core.kept, writtenBack: core.writtenBack,
            notWrittenBack: core.notWrittenBack.map(FlaggedFile.init), notSettled: core.notSettled.map(UnsureFile.init))
    }
}

/// The folders on this Mac that remember a directory, read once by ``FolderFileManaging/remembering(_:)``.
///
/// A folder remembers the directories of the other folders it has seen, and holds the delete of a missing file
/// while one of those can't be read, since the file may have moved there. Show the person each folder and held
/// file, and pass this value unchanged to ``FolderFileManaging/forget(_:)`` once they confirm the directory is
/// gone for good.
///
/// The value keeps every path exactly as the core wrote it, since the core finds each folder and hold again by
/// those bytes. Its `URL` properties are for display, and two values are equal only when those bytes are.
public struct Remembered: Sendable, Hashable {
    private let shown: MarfaCore.Remembered

    /// The directory, made absolute as a folder records it, without following symbolic links.
    public var directory: URL { folderPath(shown.dir) }
    /// Whether the registry lists the directory.
    ///
    /// A listed directory is found again by every folder at its next pass, so forgetting it changes nothing: remove
    /// it with ``Folders/remove(_:)`` first.
    public var listed: Bool { shown.listed }
    /// The listed folders that remember the directory or hold a file that waits on it.
    public var folders: [RememberingFolder] { shown.folders.map(RememberingFolder.init) }
    /// Listed folders that couldn't be read, each with why.
    public var notRead: [FolderLeft] { shown.notRead.map(FolderLeft.init) }
    /// Remembered directories that differ from ``directory`` only in case, which a forget leaves remembered.
    public var alike: [URL] { shown.alike.map(folderPath) }

    public init(
        directory: URL, listed: Bool, folders: [RememberingFolder], notRead: [FolderLeft] = [], alike: [URL] = []
    ) {
        shown = MarfaCore.Remembered(
            dir: corePath(directory), listed: listed, folders: folders.map(\.core), notRead: notRead.map(\.core),
            alike: alike.map(corePath))
    }

    init(_ core: MarfaCore.Remembered) {
        shown = core
    }

    var core: MarfaCore.Remembered { shown }
}

/// A listed folder that remembers a directory or holds a file that waits on it.
public struct RememberingFolder: Sendable, Hashable {
    private let shown: MarfaCore.RememberingFolder

    public var directory: URL { folderPath(shown.dir) }
    /// The id of the `system.folder` item whose settings the folder follows.
    public var folderId: String { shown.folder }
    /// The folder's held files that wait on the directory, empty where the registry lists it.
    public var held: [WaitingHeldFile] { shown.held.map(WaitingHeldFile.init) }

    /// Makes a folder for a scripted answer; `store` stands for the store ``FolderFileManaging/forget(_:)`` checks
    /// is still there before it writes.
    public init(directory: URL, folderId: String, store: String, held: [WaitingHeldFile] = []) {
        shown = MarfaCore.RememberingFolder(
            dir: corePath(directory), folder: folderId, store: store, held: held.map(\.core))
    }

    init(_ core: MarfaCore.RememberingFolder) {
        shown = core
    }

    var core: MarfaCore.RememberingFolder { shown }
}

/// A held file that waits on the directory a forget would forget.
public struct WaitingHeldFile: Sendable, Hashable {
    private let shown: MarfaCore.WaitingHeldFile

    /// The file's path inside its folder.
    public var path: String { shown.path }
    /// The id of the item the file stood for.
    public var item: String { shown.item }
    /// When the folder first found the file missing, as the core reports it.
    public var missingSince: String { shown.missingSince }
    /// Why the delete is held, in the core's words.
    public var reason: String { shown.reason }
    /// The other directories that keep the file held once the directory is forgotten.
    ///
    /// An empty array means forgetting can release this hold if it still waits on this directory alone.
    public var stillWaitsOn: [URL] { shown.stillWaitsOn.map(folderPath) }

    public init(path: String, item: String, missingSince: String, reason: String, stillWaitsOn: [URL] = []) {
        shown = MarfaCore.WaitingHeldFile(
            path: path, item: item, missingSince: missingSince, reason: reason,
            stillWaitsOn: stillWaitsOn.map(corePath))
    }

    init(_ core: MarfaCore.WaitingHeldFile) {
        shown = core
    }

    var core: MarfaCore.WaitingHeldFile { shown }
}

/// A folder a call didn't read or change, and why.
public struct FolderLeft: Sendable, Hashable {
    private let shown: MarfaCore.FolderLeft

    public var directory: URL { folderPath(shown.dir) }
    public var reason: String { shown.reason }

    public init(directory: URL, reason: String) {
        shown = MarfaCore.FolderLeft(dir: corePath(directory), reason: reason)
    }

    init(_ core: MarfaCore.FolderLeft) {
        shown = core
    }

    var core: MarfaCore.FolderLeft { shown }
}

/// What ``FolderFileManaging/forget(_:)`` changed.
///
/// Check ``listed`` and ``notChanged`` before telling the person the directory is forgotten everywhere.
public struct Forgotten: Sendable, Hashable {
    /// The directory the person asked to forget.
    public let directory: URL
    /// Whether the registry listed the directory when the forget checked, in which case nothing changed.
    public let listed: Bool
    /// Each folder that forgot the directory.
    public let forgotten: [ForgottenIn]
    /// Folders the preview couldn't read or the forget couldn't change, each with the reason.
    public let notChanged: [FolderLeft]

    public init(directory: URL, listed: Bool, forgotten: [ForgottenIn], notChanged: [FolderLeft] = []) {
        self.directory = directory
        self.listed = listed
        self.forgotten = forgotten
        self.notChanged = notChanged
    }

    init(_ core: MarfaCore.Forgotten) {
        self.init(
            directory: folderPath(core.dir), listed: core.listed, forgotten: core.forgotten.map(ForgottenIn.init),
            notChanged: core.notChanged.map(FolderLeft.init))
    }
}

/// A folder that forgot a directory, and what became of the held files the preview showed for it.
public struct ForgottenIn: Sendable, Hashable {
    public let directory: URL
    /// The id of the `system.folder` item whose settings the folder follows.
    public let folderId: String
    /// Paths of held files no longer held, which the folder's next sync decides again.
    public let released: [String]
    /// Held files that waited on the directory and still wait on others.
    public let stillHeld: [StillHeldFile]
    /// Held files the preview showed as staying held that now wait on nothing else; they stay held.
    ///
    /// Call ``FolderFileManaging/remembering(_:)`` again to preview their release, or settle them with
    /// ``FolderFileManaging/trashHeld(in:paths:)`` or ``FolderFileManaging/keepHeld(in:paths:writeBack:)``.
    public let notReleased: [String]

    public init(
        directory: URL, folderId: String, released: [String] = [], stillHeld: [StillHeldFile] = [],
        notReleased: [String] = []
    ) {
        self.directory = directory
        self.folderId = folderId
        self.released = released
        self.stillHeld = stillHeld
        self.notReleased = notReleased
    }

    init(_ core: MarfaCore.ForgottenIn) {
        self.init(
            directory: folderPath(core.dir), folderId: core.folder, released: core.released,
            stillHeld: core.stillHeld.map(StillHeldFile.init), notReleased: core.notReleased)
    }
}

/// A held file that still waits on other directories after a forget.
public struct StillHeldFile: Sendable, Hashable {
    /// The file's path inside its folder.
    public let path: String
    /// The directories it still waits on.
    public let stillWaitsOn: [URL]

    public init(path: String, stillWaitsOn: [URL]) {
        self.path = path
        self.stillWaitsOn = stillWaitsOn
    }

    init(_ core: MarfaCore.StillHeldFile) {
        self.init(path: core.path, stillWaitsOn: core.stillWaitsOn.map(folderPath))
    }
}

private func folderPath(_ path: String) -> URL {
    URL(filePath: path, directoryHint: .isDirectory)
}

/// A scripted value's path in the core's form, which has no trailing slash.
///
/// The slash is dropped as a scalar, since it can join the character before it in one grapheme.
private func corePath(_ url: URL) -> String {
    var path = url.path(percentEncoded: false).unicodeScalars
    if path.count > 1 && path.last == "/" { path.removeLast() }
    return String(path)
}

/// What Marfa knows about programs writing to a kept file.
public enum KeptWriters: Sendable, Hashable {
    case open
    case unknown
    case notLooked

    init(_ core: MarfaCore.KeptWriters) {
        switch core {
        case .open: self = .open
        case .unknown: self = .unknown
        case .notLooked: self = .notLooked
        }
    }
}
#endif
