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
        await #expect(throws: FakeCopyError.self) { try await folders.remembering(directory) }
        await #expect(throws: FakeCopyError.self) {
            try await folders.forget(Remembered(directory: directory, listed: false, folders: []))
        }
    }

    @Test func forgetScriptsAnswerEachCallAndKeepEveryField() async throws {
        let gone = URL(filePath: "/Volumes/Old/Notes", directoryHint: .isDirectory)
        let other = URL(filePath: "/Volumes/Other/Notes", directoryHint: .isDirectory)
        let holder = URL(filePath: "/work/notes", directoryHint: .isDirectory)
        let shown = Remembered(
            directory: gone, listed: false,
            folders: [
                RememberingFolder(
                    directory: holder, folderId: "folder-a", store: "store-a",
                    held: [
                        WaitingHeldFile(
                            path: "a.md", item: "item-a", missingSince: "2026-11-01T10:00:00Z", reason: "gone"),
                        WaitingHeldFile(
                            path: "b.md", item: "item-b", missingSince: "2026-11-02T10:00:00Z", reason: "gone",
                            stillWaitsOn: [other]),
                    ])
            ],
            notRead: [FolderLeft(directory: URL(filePath: "/work/locked"), reason: "unreadable")],
            alike: [URL(filePath: "/Volumes/Old/notes", directoryHint: .isDirectory)])
        let done = Forgotten(
            directory: gone, listed: false,
            forgotten: [
                ForgottenIn(
                    directory: holder, folderId: "folder-a", released: ["a.md"],
                    stillHeld: [StillHeldFile(path: "b.md", stillWaitsOn: [other])], notReleased: [])
            ],
            notChanged: [FolderLeft(directory: URL(filePath: "/work/locked"), reason: "unreadable")])
        let recorded = Mutex<[String]>([])
        let folders = WorkingCopy.fake().folders(
            remembering: { dir in
                recorded.withLock { $0.append("remembering \(dir.path)") }
                return shown
            },
            forget: { remembered in
                recorded.withLock { $0.append("forget \(remembered.directory.path)") }
                #expect(remembered == shown)
                return done
            })
        let read = try await folders.remembering(gone)
        #expect(read == shown)
        #expect(read.folders.first?.held.map(\.stillWaitsOn) == [[], [other]])
        #expect(try await folders.forget(read) == done)
        #expect(recorded.withLock { $0 } == ["remembering /Volumes/Old/Notes", "forget /Volumes/Old/Notes"])
    }

    /// A gone directory no folder remembers is shown with nothing in it, and forgetting it changes nothing.
    @Test(arguments: CopyKind.allCases)
    func aDirectoryNoFolderRemembersIsShownEmptyAndForgettingItChangesNothing(kind: CopyKind) async throws {
        let gone = FileManager.default.temporaryDirectory.appending(
            path: "marfa-gone-\(UUID())", directoryHint: .isDirectory)
        let folders: any FolderFileManaging
        switch kind {
        case .real:
            folders = FolderRegistry.folders()
            #expect(FolderRegistry.isNamed)
        case .fake:
            folders = WorkingCopy.fake().folders(
                remembering: { dir in
                    #expect(dir == gone)
                    return Remembered(directory: gone, listed: false, folders: [])
                },
                forget: { remembered in
                    #expect(remembered == Remembered(directory: gone, listed: false, folders: []))
                    return Forgotten(directory: gone, listed: false, forgotten: [])
                })
        }
        let shown = try await folders.remembering(gone)
        #expect(shown == Remembered(directory: gone, listed: false, folders: []))
        #expect(try await folders.forget(shown) == Forgotten(directory: gone, listed: false, forgotten: []))
    }

    /// Something standing at the path may still be the folder, or hold a file moved into it, so both calls refuse.
    @Test(arguments: CopyKind.allCases)
    func anOccupiedPathIsNeitherShownNorForgottenAndKeepsItsFile(kind: CopyKind) async throws {
        let occupied = FileManager.default.temporaryDirectory.appending(
            path: "marfa-occupied-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: occupied) }
        let file = occupied.appending(path: "moved.md")
        let bytes = Data("Moved here".utf8)
        try bytes.write(to: file)

        let folders: any FolderFileManaging
        switch kind {
        case .real:
            folders = FolderRegistry.folders()
            #expect(FolderRegistry.isNamed)
        case .fake:
            folders = WorkingCopy.fake().folders(
                remembering: { dir in
                    #expect(dir == occupied)
                    throw MarfaError.invalid(message: "it may still be the folder")
                },
                forget: { remembered in
                    #expect(remembered.directory == occupied)
                    throw MarfaError.invalid(message: "it may still be the folder")
                })
        }
        let shown = await #expect(throws: MarfaError.self) { try await folders.remembering(occupied) }
        #expect(refusesAsNotAFolder(shown))
        let forgotten = await #expect(throws: MarfaError.self) {
            try await folders.forget(Remembered(directory: occupied, listed: false, folders: []))
        }
        #expect(refusesAsNotAFolder(forgotten))
        #expect(try Data(contentsOf: file) == bytes)
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

        let reads = memory.reads
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
        #expect(memory.reads == reads, "a local held call read the keychain")

        let writtenBack = await #expect(throws: Keychain.Failure.self) {
            try await folders.keepHeld(in: directory, paths: ["held.md"], writeBack: true)
        }
        #expect(writtenBack?.status == errSecInteractionNotAllowed)
        #expect(memory.reads > reads, "the count sees a read")
    }

    /// The calls the core works locally read no sign-in, so a locked keychain doesn't stop them.
    ///
    /// Pause and resume try the sign-in, to tell the server, and go on without it. A sync reaches the server, and so
    /// reads it.
    @Test func theLocalFolderCallsReadNoSignIn() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "marfa-local-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = URL(string: "https://marfa.example")!
        let memory = MemoryKeychain()
        let server = try Server(url: home, credential: try memory.signIn(to: home))
        memory.failReads(with: errSecInteractionNotAllowed)
        let folders = FolderRegistry.folders(server: server)
        #expect(FolderRegistry.isNamed)

        var reads = memory.reads
        await #expect(throws: Never.self) { _ = try await folders.list() }
        #expect(memory.reads == reads, "list")
        let local: [(String, () async throws -> Void)] = [
            ("status", { _ = try await folders.status(of: directory) }),
            ("removeUnmatched", { _ = try await folders.removeUnmatched(in: directory, paths: ["a.md"]) }),
            ("keptFiles", { _ = try await folders.keptFiles(in: directory) }),
            ("discardKept", { _ = try await folders.discardKept(in: directory) }),
            ("confirmFirstSync", { _ = try await folders.confirmFirstSync(in: directory) }),
            ("confirmRemoval", { _ = try await folders.confirmRemoval(in: directory) }),
            ("remove", { _ = try await folders.remove(directory) }),
        ]
        for (call, work) in local {
            let refused = await #expect(throws: MarfaError.self, "\(call)") { try await work() }
            #expect(refusesAsNotAFolder(refused), "\(call)")
            #expect(memory.reads == reads, "\(call) read the keychain")
        }
        let shown = try await folders.remembering(directory)
        #expect(memory.reads == reads, "remembering read the keychain")
        _ = try await folders.forget(shown)
        #expect(memory.reads == reads, "forget read the keychain")

        let reporting: [(String, () async throws -> Void)] = [
            ("pause", { _ = try await folders.pause(directory) }),
            ("resume", { _ = try await folders.resume(directory) }),
        ]
        for (call, work) in reporting {
            let refused = await #expect(throws: MarfaError.self, "\(call)") { try await work() }
            #expect(refusesAsNotAFolder(refused), "\(call)")
            #expect(memory.reads > reads, "\(call) tries the sign-in")
            reads = memory.reads
        }

        let synced = await #expect(throws: Keychain.Failure.self) { try await folders.sync(directory) }
        #expect(synced?.status == errSecInteractionNotAllowed)
        #expect(memory.reads > reads, "the count sees a read")
    }
}
#endif
