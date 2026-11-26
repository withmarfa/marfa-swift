#if DEBUG && os(macOS)
import Foundation
import Marfa
import MarfaTesting
import Security
import Synchronization
import Testing

/// Every real folder call here reads a registry under the temporary directory, never the Mac's own.
enum FolderRegistry {
    /// Named before any folder call reads it, and named once, so no call reads the environment while it changes.
    static let file: URL = {
        let file = FileManager.default.temporaryDirectory.appending(path: "marfa-folders-\(UUID())/folders.json")
        setenv("MARFA_FOLDER_REGISTRY", file.path(percentEncoded: false), 1)
        return file
    }()

    static func folders(server: Server? = nil) -> Folders {
        _ = file
        return Folders(server: server)
    }

    /// Whether the registry the core reads is this one.
    static var isNamed: Bool {
        getenv("MARFA_FOLDER_REGISTRY").map { String(cString: $0) } == file.path(percentEncoded: false)
    }
}

/// Whether `error` is the refusal of a directory that isn't a folder.
private func refusesAsNotAFolder(_ error: (any Error)?) -> Bool {
    if case .invalid = error as? MarfaError { true } else { false }
}

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
            folders = FolderRegistry.folders()
            #expect(FolderRegistry.isNamed)
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
        let removed = await #expect(throws: MarfaError.self) {
            try await folders.removeUnmatched(in: directory, paths: ["edited.md"])
        }
        #expect(refusesAsNotAFolder(removed))
        let listed = await #expect(throws: MarfaError.self) { try await folders.keptFiles(in: directory) }
        #expect(refusesAsNotAFolder(listed))
        let discarded = await #expect(throws: MarfaError.self) { try await folders.discardKept(in: directory) }
        #expect(refusesAsNotAFolder(discarded))
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
                recorded.withLock { $0.append("trash \(dir.path) \(paths)") }
                return SettledHeld(trashed: ["a.md"], gone: ["g.md"], moved: ["m.md"], notSettled: [notSettled])
            },
            keepHeld: { dir, paths, writeBack in
                recorded.withLock { $0.append("keep \(dir.path) \(paths) \(writeBack)") }
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
                "held /example", "trash /example [\"a.md\", \"b.md\"]", "keep /example [\"a.md\"] true",
                "keep /example [\"a.md\"] false",
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
            folders = FolderRegistry.folders()
            #expect(FolderRegistry.isNamed)
        case .fake:
            folders = WorkingCopy.fake().folders(
                heldFiles: { dir in
                    #expect(dir == directory)
                    throw MarfaError.invalid(message: "not a folder")
                },
                trashHeld: { dir, paths in
                    #expect(dir == directory && paths == ["held.md"])
                    throw MarfaError.invalid(message: "not a folder")
                },
                keepHeld: { dir, paths, _ in
                    #expect(dir == directory && paths == ["held.md"])
                    throw MarfaError.invalid(message: "not a folder")
                })
        }
        let listed = await #expect(throws: MarfaError.self) { try await folders.heldFiles(in: directory) }
        #expect(refusesAsNotAFolder(listed))
        let trashed = await #expect(throws: MarfaError.self) {
            try await folders.trashHeld(in: directory, paths: ["held.md"])
        }
        #expect(refusesAsNotAFolder(trashed))
        for writeBack in [false, true] {
            let kept = await #expect(throws: MarfaError.self) {
                try await folders.keepHeld(in: directory, paths: ["held.md"], writeBack: writeBack)
            }
            #expect(refusesAsNotAFolder(kept))
        }
        #expect(try Data(contentsOf: file) == bytes)
    }

    /// Listing, trashing and keeping without write-back are local, so a locked keychain doesn't stop them;
    /// write-back pulls, and so reads the sign-in.
    @Test func theLocalHeldCallsReadNoSignIn() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "marfa-held-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = URL(string: "https://marfa.example")!
        let memory = MemoryKeychain()
        let server = try Server(url: home, credential: try memory.signIn(to: home))
        memory.failReads(with: errSecInteractionNotAllowed)
        let folders = FolderRegistry.folders(server: server)
        #expect(FolderRegistry.isNamed)

        let listed = await #expect(throws: MarfaError.self) { try await folders.heldFiles(in: directory) }
        #expect(refusesAsNotAFolder(listed))
        let trashed = await #expect(throws: MarfaError.self) {
            try await folders.trashHeld(in: directory, paths: ["held.md"])
        }
        #expect(refusesAsNotAFolder(trashed))
        let kept = await #expect(throws: MarfaError.self) {
            try await folders.keepHeld(in: directory, paths: ["held.md"], writeBack: false)
        }
        #expect(refusesAsNotAFolder(kept))

        let writtenBack = await #expect(throws: Keychain.Failure.self) {
            try await folders.keepHeld(in: directory, paths: ["held.md"], writeBack: true)
        }
        #expect(writtenBack?.status == errSecInteractionNotAllowed)
    }
}
#endif
