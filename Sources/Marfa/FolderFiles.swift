#if os(macOS)
import Foundation
internal import MarfaCore

/// The local folder operations that manage unmatched and kept files.
public protocol FolderFileManaging: Sendable {
    func removeUnmatched(in directory: URL, paths: [String]) async throws -> UnmatchedRemoved
    func keptFiles(in directory: URL) async throws -> [KeptFile]
    func discardKept(in directory: URL) async throws -> KeptDiscarded
    func heldFiles(in directory: URL) async throws -> [HeldFile]
    func trashHeld(in directory: URL, paths: [String]) async throws -> SettledHeld
    func keepHeld(in directory: URL, paths: [String], writeBack: Bool) async throws -> SettledHeld
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
/// It stays held until the person settles it with ``FolderFileManaging/trashHeld(in:paths:)`` or
/// ``FolderFileManaging/keepHeld(in:paths:writeBack:)``.
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
/// A file the call could not settle is in ``notSettled`` with why, and stays held: check it before telling the
/// person the delete went through.
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
    /// Named files left as they were and still held, each with why.
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
