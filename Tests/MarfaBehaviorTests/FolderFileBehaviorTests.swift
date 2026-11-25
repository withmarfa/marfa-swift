#if DEBUG && os(macOS)
import Foundation
import Marfa
import MarfaTesting
import Testing

@Suite(.timeLimit(.minutes(1)))
struct FolderFileBehaviorTests {
    @Test func folderScriptsReturnTheSelectedPathsAndDirectories() async throws {
        let fake = WorkingCopy.fake()
        let directory = URL(filePath: "/example")
        let kept = KeptFile(path: "aside", from: "notes/a.md", writers: .unknown, until: "2026-12-01", reason: "busy")
        let folders = fake.folders(
            removeUnmatched: { _, paths in
                .init(removed: paths.map { .init(path: $0, itemId: nil) }, kept: [], ended: 1)
            },
            keptFiles: { _ in [kept] },
            discardKept: { _ in .init(discarded: [], putBack: ["b.md"], kept: [kept]) })
        #expect(
            try await folders.removeUnmatched(in: directory, paths: ["a"]).removed == [.init(path: "a", itemId: nil)])
        #expect(try await folders.keptFiles(in: directory) == [kept])
        #expect(try await folders.discardKept(in: directory) == .init(discarded: [], putBack: ["b.md"], kept: [kept]))
        let client = fake.folderClient { id, under in
            .init(
                folderId: id, under: under ?? "", directFiles: 1, totalFiles: 2, unreadablePlacements: 0,
                directories: [])
        }
        let page = try await client.folderDirectories("folder", under: "notes")
        #expect(page.folderId == "folder" && page.under == "notes" && page.directFiles == 1 && page.totalFiles == 2)
    }

    @Test(arguments: CopyKind.allCases)
    func anUnregisteredDirectoryKeepsItsFile(kind: CopyKind) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "marfa-folder-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("Keep my changes".utf8)
        let file = directory.appending(path: "edited.md")
        try bytes.write(to: file)

        let folders: any FolderFileManaging
        switch kind {
        case .real:
            folders = Folders()
        case .fake:
            folders = WorkingCopy.fake().folders(
                removeUnmatched: { dir, paths in
                    #expect(dir == directory && paths == ["edited.md"])
                    throw MarfaError.invalid(message: "unregistered directory")
                },
                keptFiles: { dir in
                    #expect(dir == directory)
                    throw MarfaError.invalid(message: "unregistered directory")
                },
                discardKept: { dir in
                    #expect(dir == directory)
                    throw MarfaError.invalid(message: "unregistered directory")
                })
        }
        await #expect(throws: MarfaError.self) {
            try await folders.removeUnmatched(in: directory, paths: ["edited.md"])
        }
        await #expect(throws: MarfaError.self) { try await folders.keptFiles(in: directory) }
        await #expect(throws: MarfaError.self) { try await folders.discardKept(in: directory) }
        #expect(try Data(contentsOf: file) == bytes)
    }
}
#endif
