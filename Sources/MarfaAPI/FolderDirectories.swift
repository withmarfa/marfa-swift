import Marfa
import MarfaTypes

/// Reads the immediate subdirectories of a path from the placements visible to the caller.
public protocol FolderDirectoryReading: Sendable {
    func folderDirectories(_ id: String, under: String?) async throws -> Components.Schemas.FolderDirectories
}

extension Client: FolderDirectoryReading {
    /// Reads one level of a folder and its file counts, starting at the top level when `under` is omitted.
    public func folderDirectories(_ id: String, under: String? = nil) async throws(MarfaError)
        -> Components.Schemas.FolderDirectories
    {
        try await answer("getFolderDirectories") {
            try await getFolderDirectories(path: .init(id: id), query: .init(under: under)).ok.body.json
        }
    }
}
