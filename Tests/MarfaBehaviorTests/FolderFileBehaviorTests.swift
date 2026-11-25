#if DEBUG && os(macOS)
import Foundation
import Marfa
import MarfaTesting
import Testing

@Suite(.timeLimit(.minutes(1)))
struct FolderFileBehaviorTests {
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
