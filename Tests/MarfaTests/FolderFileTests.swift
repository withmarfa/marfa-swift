#if os(macOS)
import Foundation
import Marfa
import MarfaAPI
import Testing

extension LiveWorkingCopies {
    @Suite(.enabled(if: Live.server != nil), .timeLimit(.minutes(2)))
    struct LiveFolderFiles {
        @Test func removingUnmatchedKeepsAnEditedFileAndLeavesTheItems() async throws {
            let server = try #require(Live.server)
            let copy = try await WorkingCopy.open(store: Live.store(), server: server)
            _ = try await copy.hydrate(types: ["system.folder", "core.note"], tier: .library)
            let folder = try await copy.createFolder(
                FolderSettings(
                    title: "Folder files",
                    query: FolderQuery(types: ["core.note"], filter: "tags contains \"\(UUID())\"")))
            let directory = FolderFixture.directory()
            let folders = FolderFixture.folders
            _ = try await folders.add(directory, following: folder.id)
            let subdirectory = directory.appending(path: "Drafts")
            try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            try FolderFixture.note("Remove", in: subdirectory)
            try FolderFixture.note("Edited", in: subdirectory)
            try await folders.confirmFirstSync(in: directory)
            _ = try await FolderFixture.sync(directory)
            let files = try await folders.status(of: directory).files
            let removable = try #require(files.first { $0.path == "Drafts/Remove.md" && $0.state == .unmatched })
            let edited = try #require(files.first { $0.path == "Drafts/Edited.md" && $0.state == .unmatched })
            let id = try #require(removable.itemId)
            let client = Client(server)
            let root = try await client.folderDirectories(folder.id)
            #expect(root.folderId == folder.id && root.under == "" && root.unreadablePlacements == 0)
            let drafts = try #require(root.directories.first { $0.path == "Drafts" })
            #expect(drafts.directFiles == 2 && drafts.allFiles == 2 && !drafts.hasDirectories)
            let child = try await client.folderDirectories(folder.id, under: "Drafts")
            #expect(child.under == "Drafts" && child.directFiles == 2 && child.totalFiles == 2)
            let bytes = Data("A local edit".utf8)
            let editedURL = directory.appending(path: edited.path)
            try bytes.write(to: editedURL)

            let offline = Folders()
            let result = try await offline.removeUnmatched(
                in: directory, paths: [edited.path, removable.path, removable.path])
            #expect(result.removed == [.init(path: removable.path, itemId: id)] && result.ended == 1)
            #expect(
                result.kept == [
                    .init(
                        path: edited.path, itemId: edited.itemId, reason: "its bytes differ from what the folder wrote")
                ])
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: removable.path).path()))
            #expect(try Data(contentsOf: editedURL) == bytes)
            #expect(try await offline.keptFiles(in: directory).isEmpty)
            #expect(try await offline.discardKept(in: directory) == .init(discarded: [], putBack: [], kept: []))
            #expect(try Data(contentsOf: editedURL) == bytes)
            _ = try await FolderFixture.sync(directory)
            _ = try await copy.catchUp()
            #expect(try await copy.items.get(id)?.state == .active)
            await copy.close()
        }
    }
}
#endif
