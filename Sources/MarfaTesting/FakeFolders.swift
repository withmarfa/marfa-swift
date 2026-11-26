#if DEBUG
import Foundation
import Marfa
import MarfaAPI

extension FakeCopy {
    /// Scripts the server's directory read by folder ID and relative path.
    public func folderClient(
        directories: @escaping @Sendable (String, String?) throws -> Components.Schemas.FolderDirectories
    ) -> some FolderDirectoryReading {
        ScriptedDirectories(read: directories)
    }
}

private struct ScriptedDirectories: FolderDirectoryReading {
    let read: @Sendable (String, String?) throws -> Components.Schemas.FolderDirectories

    func folderDirectories(_ id: String, under: String?) async throws -> Components.Schemas.FolderDirectories {
        try read(id, under)
    }
}

#if os(macOS)
extension FakeCopy {
    /// Scripts local folder operations without opening a directory or the folder registry.
    public func folders(
        removeUnmatched: @escaping @Sendable (URL, [String]) throws -> UnmatchedRemoved = { _, _ in
            throw FakeCopyError.unsupported(call: "folders.removeUnmatched")
        },
        keptFiles: @escaping @Sendable (URL) throws -> [KeptFile] = { _ in
            throw FakeCopyError.unsupported(call: "folders.keptFiles")
        },
        discardKept: @escaping @Sendable (URL) throws -> KeptDiscarded = { _ in
            throw FakeCopyError.unsupported(call: "folders.discardKept")
        },
        heldFiles: @escaping @Sendable (URL) throws -> [HeldFile] = { _ in
            throw FakeCopyError.unsupported(call: "folders.heldFiles")
        },
        trashHeld: @escaping @Sendable (URL, [String]) throws -> SettledHeld = { _, _ in
            throw FakeCopyError.unsupported(call: "folders.trashHeld")
        },
        keepHeld: @escaping @Sendable (URL, [String], Bool) throws -> SettledHeld = { _, _, _ in
            throw FakeCopyError.unsupported(call: "folders.keepHeld")
        },
        remembering: @escaping @Sendable (URL) throws -> Remembered = { _ in
            throw FakeCopyError.unsupported(call: "folders.remembering")
        },
        forget: @escaping @Sendable (Remembered) throws -> Forgotten = { _ in
            throw FakeCopyError.unsupported(call: "folders.forget")
        }
    ) -> some FolderFileManaging {
        ScriptedFolderFiles(
            remove: removeUnmatched, list: keptFiles, discard: discardKept, held: heldFiles, trash: trashHeld,
            keep: keepHeld, recall: remembering, forgetting: forget)
    }
}

private struct ScriptedFolderFiles: FolderFileManaging {
    let remove: @Sendable (URL, [String]) throws -> UnmatchedRemoved
    let list: @Sendable (URL) throws -> [KeptFile]
    let discard: @Sendable (URL) throws -> KeptDiscarded
    let held: @Sendable (URL) throws -> [HeldFile]
    let trash: @Sendable (URL, [String]) throws -> SettledHeld
    let keep: @Sendable (URL, [String], Bool) throws -> SettledHeld
    let recall: @Sendable (URL) throws -> Remembered
    let forgetting: @Sendable (Remembered) throws -> Forgotten

    func removeUnmatched(in directory: URL, paths: [String]) async throws -> UnmatchedRemoved {
        try remove(directory, paths)
    }

    func keptFiles(in directory: URL) async throws -> [KeptFile] { try list(directory) }

    func discardKept(in directory: URL) async throws -> KeptDiscarded { try discard(directory) }

    func heldFiles(in directory: URL) async throws -> [HeldFile] { try held(directory) }

    func trashHeld(in directory: URL, paths: [String]) async throws -> SettledHeld { try trash(directory, paths) }

    func keepHeld(in directory: URL, paths: [String], writeBack: Bool) async throws -> SettledHeld {
        try keep(directory, paths, writeBack)
    }

    func remembering(_ directory: URL) async throws -> Remembered { try recall(directory) }

    func forget(_ remembered: Remembered) async throws -> Forgotten { try forgetting(remembered) }
}
#endif
#endif
