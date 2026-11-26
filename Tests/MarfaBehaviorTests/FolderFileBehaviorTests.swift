#if DEBUG && os(macOS)
import Foundation
import Marfa
import MarfaTesting
import Synchronization
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

    @Test func heldScriptsAnswerEachCallAndKeepEveryField() async throws {
        let directory = URL(filePath: "/example")
        let held = HeldFile(
            path: "a.md", item: "item-a", missingSince: "2026-11-01T10:00:00Z", reason: "another folder may hold it")
        let notSettled = UnsureFile(path: "b.md", reason: "a file is at its path again")
        let notWritten = FlaggedFile(path: "c.md", flag: "outside", reason: "the query no longer holds it", item: "c")
        let recorded = Mutex<[String]>([])
        let folders = WorkingCopy.fake().folders(
            heldFiles: { dir in
                recorded.withLock { $0.append("held \(dir.path)") }
                return [held]
            },
            trashHeld: { dir, paths in
                recorded.withLock { $0.append("trash \(paths)") }
                return SettledHeld(trashed: ["a.md"], gone: ["g.md"], moved: ["m.md"], notSettled: [notSettled])
            },
            keepHeld: { _, paths, writeBack in
                recorded.withLock { $0.append("keep \(paths) \(writeBack)") }
                return SettledHeld(
                    kept: paths, writtenBack: writeBack ? ["a.md"] : [], notWrittenBack: [notWritten],
                    notSettled: [])
            })
        #expect(try await folders.heldFiles(in: directory) == [held])
        let trashed = try await folders.trashHeld(in: directory, paths: ["a.md", "b.md"])
        #expect(trashed.trashed == ["a.md"] && trashed.gone == ["g.md"] && trashed.moved == ["m.md"])
        #expect(trashed.notSettled == [notSettled] && trashed.kept.isEmpty)
        let kept = try await folders.keepHeld(in: directory, paths: ["a.md"], writeBack: true)
        #expect(kept.kept == ["a.md"] && kept.writtenBack == ["a.md"] && kept.notWrittenBack == [notWritten])
        let keptOnly = try await folders.keepHeld(in: directory, paths: ["a.md"], writeBack: false)
        #expect(keptOnly.writtenBack.isEmpty)
        #expect(
            recorded.withLock { $0 } == [
                "held /example", "trash [\"a.md\", \"b.md\"]", "keep [\"a.md\"] true", "keep [\"a.md\"] false",
            ])
    }

    @Test func unscriptedHeldCallsAreUnsupported() async throws {
        let folders = WorkingCopy.fake().folders()
        let directory = URL(filePath: "/example")
        await #expect(throws: FakeCopyError.self) { try await folders.heldFiles(in: directory) }
        await #expect(throws: FakeCopyError.self) { try await folders.trashHeld(in: directory, paths: ["a"]) }
        await #expect(throws: FakeCopyError.self) {
            try await folders.keepHeld(in: directory, paths: ["a"], writeBack: true)
        }
    }

    @Test(arguments: CopyKind.allCases)
    func aPathThatIsNotAFolderRefusesTheHeldCallsAndKeepsItsFile(kind: CopyKind) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "marfa-held-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "held.md")
        let bytes = Data("Mine".utf8)
        try bytes.write(to: file)

        let folders: any FolderFileManaging
        switch kind {
        case .real:
            folders = Folders()
        case .fake:
            folders = WorkingCopy.fake().folders(
                heldFiles: { _ in throw MarfaError.invalid(message: "not a folder") },
                trashHeld: { _, _ in throw MarfaError.invalid(message: "not a folder") },
                keepHeld: { _, _, _ in throw MarfaError.invalid(message: "not a folder") })
        }
        await #expect(throws: MarfaError.self) { try await folders.heldFiles(in: directory) }
        await #expect(throws: MarfaError.self) { try await folders.trashHeld(in: directory, paths: ["held.md"]) }
        await #expect(throws: MarfaError.self) {
            try await folders.keepHeld(in: directory, paths: ["held.md"], writeBack: true)
        }
        #expect(try Data(contentsOf: file) == bytes)
    }
}
#endif
