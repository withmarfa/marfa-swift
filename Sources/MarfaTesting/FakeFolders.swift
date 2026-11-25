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
        }
    ) -> some FolderFileManaging {
        ScriptedFolderFiles(remove: removeUnmatched, list: keptFiles, discard: discardKept)
    }
}

private struct ScriptedFolderFiles: FolderFileManaging {
    let remove: @Sendable (URL, [String]) throws -> UnmatchedRemoved
    let list: @Sendable (URL) throws -> [KeptFile]
    let discard: @Sendable (URL) throws -> KeptDiscarded

    func removeUnmatched(in directory: URL, paths: [String]) async throws -> UnmatchedRemoved {
        try remove(directory, paths)
    }

    func keptFiles(in directory: URL) async throws -> [KeptFile] { try list(directory) }

    func discardKept(in directory: URL) async throws -> KeptDiscarded { try discard(directory) }
}
#endif
#endif
