#if os(macOS)
import Foundation
import Testing

@testable import Marfa

/// Every folder these tests add is listed in a registry under the temporary directory, never the Mac's own.
enum FolderFixture {
    /// Named before any folder call reads it, and named once, so no call reads the environment while it changes.
    static let registry: URL = {
        let file = FileManager.default.temporaryDirectory.appending(path: "marfa-folders-\(UUID())/folders.json")
        setenv("MARFA_FOLDER_REGISTRY", file.path(percentEncoded: false), 1)
        return file
    }()

    static var folders: Folders {
        _ = registry
        return Folders(server: Live.server)
    }

    /// A `marfa` binary to hold the package's registry to, where `MARFA_CLI` names one.
    static var commandLine: URL? {
        ProcessInfo.processInfo.environment["MARFA_CLI"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
    }

    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "marfa-folder-\(UUID())", directoryHint: .isDirectory)
    }

    /// Makes a `system.folder` of the notes tagged with a tag of its own, so the folder holds only what the test
    /// writes, and answers its id.
    static func settings(removalThreshold: [String: Any]? = nil) async throws -> String {
        try await folder(removalThreshold: removalThreshold).id
    }

    /// The same, and the tag its notes carry.
    static func folder(removalThreshold: [String: Any]? = nil) async throws -> (id: String, tag: String) {
        let server = try #require(Live.server)
        let tag = "folder\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
        var body: [String: Any] = [
            "title": tag,
            "search": ["types": ["core.note"], "filter": "tags contains \"\(tag)\""],
            "defaults": ["tags": [tag]],
        ]
        if let removalThreshold { body["removal_threshold"] = removalThreshold }
        var request = URLRequest(url: server.url.appending(path: "folders"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(server.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (answer, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        try #require(
            status == 201, "making a folder answered \(status ?? 0): \(String(decoding: answer, as: UTF8.self))")
        let made = try JSONDecoder().decode(JSONValue.self, from: answer)
        return (try #require(made["item"]?["id"]?.string), tag)
    }

    /// A folder added, its first sync confirmed and synced once, so its copy holds its settings.
    static func synced(removalThreshold: [String: Any]? = nil) async throws -> URL {
        let directory = directory()
        _ = try await folders.add(directory, following: try await settings(removalThreshold: removalThreshold))
        try await folders.confirmFirstSync(in: directory)
        _ = try await sync(directory)
        return directory
    }

    /// A sync that ran, not one waiting for the first sync to be confirmed.
    static func sync(_ directory: URL) async throws -> FolderSync {
        switch try await folders.sync(directory) {
        case .synced(let sync): return sync
        case .awaitingConfirmation(let plan): throw FirstSyncWaits(plan: plan)
        }
    }

    struct FirstSyncWaits: Error { let plan: FirstSyncPlan }

    /// A note on the server that the folder whose notes carry `tag` takes: a folder takes the library, not the feed.
    static func note(_ title: String, tagged tag: String) -> Draft {
        Draft(
            type: "core.note", properties: ["title": .string(title), "body": "Written by a test."], tags: [tag],
            tier: .library)
    }

    static func note(_ name: String, in directory: URL) throws {
        try Data("---\ntitle: \(name)\n---\nWritten by a test.\n".utf8)
            .write(to: directory.appending(path: "\(name).md"))
    }

    static func listed(_ directory: URL, in listed: [ListedFolder]) -> Bool {
        listed.contains { $0.directory.lastPathComponent == directory.lastPathComponent }
    }

    /// Runs the command-line tool with this process's environment, the registry's name and the server's among
    /// it, and answers what it printed.
    static func run(_ arguments: [String]) throws -> Data {
        let binary = try #require(commandLine)
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "marfa \(arguments.joined(separator: " ")) failed")
        return printed
    }
}

extension JSONValue {
    fileprivate subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    fileprivate var array: [JSONValue]? {
        if case .array(let array) = self { array } else { nil }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MARFA_LIVE_REQUIRED"] != nil), .timeLimit(.minutes(1)))
func theFolderTestsHaveTheCommandLineWhereTheyAreRequired() {
    #expect(FolderFixture.commandLine != nil, "MARFA_LIVE_REQUIRED is set, and MARFA_CLI names no marfa binary")
}

@Test(.timeLimit(.minutes(1)))
func addingAFolderAgainstAServerOutOfReachThrowsAndLeavesNothing() async throws {
    _ = FolderFixture.registry
    let directory = FolderFixture.directory()
    let folders = Folders(server: Server(url: URL(string: "http://127.0.0.1:9")!, key: "unused"))
    await #expect {
        try await folders.add(directory, following: "01a00000-0000-7000-8000-000000000001")
    } throws: { error in
        if case .network = error as? MarfaError { true } else { false }
    }
    #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
}

@Test(.timeLimit(.minutes(1)))
func aDirectoryThatIsNotAFolderIsRefused() async throws {
    let directory = FolderFixture.directory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    await #expect {
        try await FolderFixture.folders.status(of: directory)
    } throws: { error in
        if case .invalid(let message) = error as? MarfaError { message.contains("is not a folder") } else { false }
    }
}

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveFolders {
        let folders = FolderFixture.folders

        @Test func aFolderAddedHereIsInTheRegistryTheCommandLineReads() async throws {
            let directory = FolderFixture.directory()
            let id = try await FolderFixture.settings()
            let added = try await folders.add(directory, following: id)
            #expect(added.folderId == id)
            #expect(FolderFixture.listed(directory, in: try await folders.list()))
            // The file `marfa folders list` reads where MARFA_FOLDER_REGISTRY names it.
            let file = try Data(contentsOf: FolderFixture.registry)
            let registry = try JSONDecoder().decode(JSONValue.self, from: file)
            let dirs = registry["folders"]?.array?.compactMap { $0["dir"]?.string } ?? []
            #expect(dirs.contains { $0.hasSuffix(directory.lastPathComponent) }, "\(dirs)")
        }

        @Test(.enabled(if: FolderFixture.commandLine != nil, "set MARFA_CLI to a marfa binary"))
        func theCommandLineAndThePackageShareOneRegistry() async throws {
            let ours = FolderFixture.directory()
            _ = try await folders.add(ours, following: try await FolderFixture.settings())
            let printed = try FolderFixture.run(["--json", "folders", "list"])
            let listed = try JSONDecoder().decode([JSONValue].self, from: printed).compactMap { $0["dir"]?.string }
            #expect(listed.contains { $0.hasSuffix(ours.lastPathComponent) }, "\(listed)")

            let theirs = FolderFixture.directory()
            let id = try await FolderFixture.settings()
            _ = try FolderFixture.run(["folders", "add", theirs.path(percentEncoded: false), "--folder", id, "--yes"])
            let seen = try await folders.list()
            #expect(FolderFixture.listed(theirs, in: seen))
            #expect(seen.first { $0.directory.lastPathComponent == theirs.lastPathComponent }?.folderId == id)
        }

        @Test func aSyncSendsANewFileAndItsStatusIsInStep() async throws {
            let directory = FolderFixture.directory()
            _ = try await folders.add(directory, following: try await FolderFixture.settings())
            try FolderFixture.note("First", in: directory)
            // The first sync reads the folder and waits; nothing is sent.
            let waiting = try await folders.sync(directory)
            guard case .awaitingConfirmation(let plan) = waiting else {
                Issue.record("the first sync ran without being confirmed: \(waiting)")
                return
            }
            #expect(plan == FirstSyncPlan(write: 0, send: 1, beside: 0))
            #expect(try await folders.status(of: directory).firstSync?.plan == plan)
            await #expect {
                try await folders.watch(directory)
            } throws: { error in
                if case .firstSyncWaiting = error as? MarfaError { true } else { false }
            }
            #expect(try await folders.confirmFirstSync(in: directory))
            #expect(!(try await folders.confirmFirstSync(in: directory)))
            #expect(try await folders.status(of: directory).firstSync == nil)
            let synced = try await FolderFixture.sync(directory)
            #expect(synced.catchUpError == nil)
            #expect(synced.pass.drain.answered >= 1)
            #expect(synced.pass.pull != nil)
            let status = try await folders.status(of: directory)
            #expect(status.files.map(\.path) == ["First.md"])
            #expect(status.files.allSatisfy { $0.state == .inStep }, "\(status.files)")
            #expect(!status.paused.isPaused)
        }

        @Test func aSyncLeavesTheFilesItWroteInStepAndCountsTheirPlacements() async throws {
            let (folderId, tag) = try await FolderFixture.folder()
            let writer = try await Live.hydrated()
            for title in ["Alpha", "Beta"] {
                _ = try await writer.items.create(FolderFixture.note(title, tagged: tag))
            }
            #expect(try await writer.queue.drain().verdicts.allSatisfy { $0.verdict == .accepted })
            await writer.close()

            let directory = FolderFixture.directory()
            _ = try await folders.add(directory, following: folderId)
            try await folders.confirmFirstSync(in: directory)
            let synced = try await FolderFixture.sync(directory)

            #expect(synced.pass.pull?.written == 2)
            // The pull queued a placement for each file it wrote, and the sync's second drain sent them.
            #expect(synced.pass.drain.answered >= 2, "\(synced.pass.drain)")
            let verdicts = synced.pass.drain.verdicts
            #expect(verdicts.allSatisfy { $0.verdict == .accepted }, "\(verdicts)")
            let status = try await folders.status(of: directory)
            #expect(status.files.map(\.path).sorted() == ["Alpha.md", "Beta.md"])
            #expect(status.files.allSatisfy { $0.state == .inStep }, "\(status.files)")
        }

        @Test func aSyncNamesTheItemItsPullDidNotWriteAtASecretsName() async throws {
            let (folderId, tag) = try await FolderFixture.folder()
            let writer = try await Live.hydrated()
            let secret = try #require(try await writer.items.create(FolderFixture.note("id_rsa", tagged: tag)).itemId)
            let ordinary = try #require(
                try await writer.items.create(FolderFixture.note("Ordinary", tagged: tag)).itemId)
            #expect(try await writer.queue.drain().verdicts.allSatisfy { $0.verdict == .accepted })
            await writer.close()

            let directory = FolderFixture.directory()
            _ = try await folders.add(directory, following: folderId)
            try await folders.confirmFirstSync(in: directory)
            let synced = try await FolderFixture.sync(directory)

            let held = try #require(synced.pass.flagged.first { $0.item == secret }, "\(synced.pass.flagged)")
            #expect(held.flag == "outside" && held.path == "id_rsa.md", "\(held)")
            #expect(!held.reason.isEmpty)
            // The witness: the item beside it was written, and is not named as held back.
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "Ordinary.md").path()))
            #expect(!synced.pass.flagged.contains { $0.item == ordinary }, "\(synced.pass.flagged)")
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: held.path).path()))
        }

        @Test func aSyncCarriesAConflictedEditAndTheFileItsTextWentTo() async throws {
            let (folderId, tag) = try await FolderFixture.folder()
            let title = "Conflicted \(UUID().uuidString.prefix(8))"
            let writer = try await Live.hydrated()
            let note = try #require(try await writer.items.create(FolderFixture.note(title, tagged: tag)).itemId)
            #expect(try await writer.queue.drain().verdicts.allSatisfy { $0.verdict == .accepted })

            let directory = FolderFixture.directory()
            _ = try await folders.add(directory, following: folderId)
            try await folders.confirmFirstSync(in: directory)
            _ = try await FolderFixture.sync(directory)
            let path = try #require(
                try await folders.status(of: directory).files.first { $0.itemId == note }?.path,
                "the first sync wrote no file for the note")
            let file = directory.appending(path: path)
            #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))

            // Another device edits the body the folder's file is based on, and the person edits the file.
            _ = try await writer.items.update(note, Edit(properties: ["body": "elsewhere"], baseVersion: 1))
            #expect(try await writer.queue.drain().verdicts.allSatisfy { $0.verdict == .accepted })
            await writer.close()
            try Data("---\ntitle: \(title)\n---\nWritten here.\n".utf8).write(to: file)

            let synced = try await FolderFixture.sync(directory)
            let conflicts = synced.pass.drain.verdicts.compactMap { write -> (item: String?, copy: String)? in
                guard case .conflicted(let copy, _)? = write.verdict else { return nil }
                return (write.itemId, copy)
            }
            let conflict = try #require(conflicts.first { $0.item == note }, "\(synced.pass.drain.verdicts)")
            let files = try await folders.status(of: directory).files
            #expect(files.contains { $0.itemId == conflict.copy }, "the copy is no file of the folder: \(files)")
        }

        @Test func aFirstSyncStillWaitingIsCancelledByRemovingTheFolderAndTheFilesStay() async throws {
            let directory = FolderFixture.directory()
            _ = try await folders.add(directory, following: try await FolderFixture.settings())
            try FolderFixture.note("Kept", in: directory)
            guard case .awaitingConfirmation = try await folders.sync(directory) else {
                Issue.record("the first sync ran without being confirmed")
                return
            }
            try await folders.remove(directory)
            #expect(!FolderFixture.listed(directory, in: try await folders.list()))
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "Kept.md").path()))
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: ".marfa").path()))
        }

        @Test func aFolderIsNotRemovedWhileWritesWaitAndIsOnceTheyAreSent() async throws {
            let directory = try await FolderFixture.synced()
            try FolderFixture.note("Waiting", in: directory)
            // Without a server the sync reads the new file, queues it and stops short of sending it.
            await #expect {
                try await Folders().sync(directory)
            } throws: { error in
                if case .noServer = error as? MarfaError { true } else { false }
            }
            #expect(try await folders.status(of: directory).files.contains { $0.state == .waiting })
            await #expect {
                try await folders.remove(directory)
            } throws: { error in
                if case .invalid(let message) = error as? MarfaError { message.contains("not yet sent") } else { false }
            }

            _ = try await folders.sync(directory)
            try await folders.remove(directory)
            #expect(!FolderFixture.listed(directory, in: try await folders.list()))
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "Waiting.md").path()))
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: ".marfa").path()))
        }

        @Test func aFolderWhoseDirectoryIsGoneIsTakenOffTheRegistry() async throws {
            let directory = try await FolderFixture.synced()
            // The witness: it is listed before the directory goes.
            #expect(FolderFixture.listed(directory, in: try await folders.list()))
            try FileManager.default.removeItem(at: directory)
            await #expect(throws: MarfaError.self) { try await folders.status(of: directory) }
            await #expect(throws: MarfaError.self) { try await folders.sync(directory) }
            try await folders.remove(directory)
            #expect(!FolderFixture.listed(directory, in: try await folders.list()))
        }

        @Test func aPausedRemovalIsRestoredOrConfirmed() async throws {
            let directory = try await FolderFixture.synced(removalThreshold: ["files": 1, "fraction": 0.1])
            let names = ["One", "Two", "Three"]
            for name in names { try FolderFixture.note(name, in: directory) }
            #expect(try await FolderFixture.sync(directory).pass.drain.answered >= 3)

            func removeAll() async throws -> FolderSync {
                for name in names { try FileManager.default.removeItem(at: directory.appending(path: "\(name).md")) }
                return try await FolderFixture.sync(directory)
            }
            #expect(try await removeAll().pass.scan.paused == 3)
            #expect(try await folders.status(of: directory).paused == PausedRemoval(disk: 3))
            let restored = try await folders.restoreRemoval(in: directory)
            #expect(restored.putBack == 3)
            for name in names {
                #expect(FileManager.default.fileExists(atPath: directory.appending(path: "\(name).md").path()))
            }
            _ = try await folders.sync(directory)
            #expect(!(try await folders.status(of: directory).paused.isPaused))

            #expect(try await removeAll().pass.scan.paused == 3)
            let confirmed = try await folders.confirmRemoval(in: directory)
            #expect(confirmed.deleted == 3)
            #expect(confirmed.unsure.isEmpty)
            let sent = try await FolderFixture.sync(directory)
            #expect(sent.pass.drain.answered >= 3)
            #expect(try await folders.status(of: directory) == FolderStatus(files: []))
        }

        @Test func aWatchKeepsTheFolderInStepHoldsItAndLetsItGoWhenStopped() async throws {
            let directory = try await FolderFixture.synced()
            let watch = try await folders.watch(directory)
            let heard = Task {
                var events: [FolderEvent] = []
                for try await event in watch {
                    events.append(event)
                    if case .passed(let pass) = event, pass.scan.created == 1, pass.drain.answered >= 1 { break }
                }
                return events
            }
            await #expect {
                try await folders.sync(directory)
            } throws: { error in
                if case .readingHandle = error as? MarfaError { true } else { false }
            }
            try FolderFixture.note("Watched", in: directory)
            let events = try await bounded("a pass that sends the new file", within: 60) { try await heard.value }
            #expect(events.contains { if case .watching = $0 { true } else { false } })
            #expect(try await folders.status(of: directory).files.map(\.path) == ["Watched.md"])

            try await bounded("the watch to stop", within: 20) { await watch.stop() }
            _ = try await folders.sync(directory)
        }

        @Test func aWatchEndsWithoutAnErrorWhenItIsStopped() async throws {
            let directory = try await FolderFixture.synced()
            let watch = try await folders.watch(directory)
            let ended = Task {
                var passes = 0
                for try await event in watch {
                    if case .passed = event { passes += 1 }
                }
                return passes
            }
            try FolderFixture.note("Stopped", in: directory)
            try await eventually("a pass sends the file", within: 30) {
                let files = try await folders.status(of: directory).files
                return files.contains { $0.path == "Stopped.md" && $0.state == .inStep }
            }
            try await bounded("the watch to stop", within: 20) { await watch.stop() }
            let passes = try await bounded("the events to end", within: 5) { try await ended.value }
            #expect(passes >= 1)
        }

        @Test func cancellingTheTaskThatIteratesAWatchStopsItAndFreesTheFolder() async throws {
            let directory = try await FolderFixture.synced()
            let watch = try await folders.watch(directory)
            let iterating = Task {
                for try await _ in watch {}
            }
            // The witness: the folder is held while the watch runs.
            await #expect(throws: MarfaError.self) { try await folders.sync(directory) }
            iterating.cancel()
            try await eventually("a sync after the cancel", within: 20) {
                (try? await folders.sync(directory)) != nil
            }
        }

        @Test func releasingAWatchNobodyIteratesStopsItAndFreesTheFolder() async throws {
            let directory = try await FolderFixture.synced()
            var watch: FolderWatch? = try await folders.watch(directory)
            await #expect(throws: MarfaError.self) { try await folders.sync(directory) }
            #expect(watch != nil)
            watch = nil
            try await eventually("a sync after the release", within: 20) {
                (try? await folders.sync(directory)) != nil
            }
        }

        @Test func aWatchWhoseCredentialIsRefusedEndsByThrowing() async throws {
            let directory = try await FolderFixture.synced()
            let server = try #require(Live.server)
            let refused = Folders(server: Server(url: server.url, key: "marfa_not_a_key"))
            let watch = try await refused.watch(directory)
            let ended = try await bounded("the refused watch to end", within: 60) {
                do {
                    for try await _ in watch {}
                    return MarfaError?.none
                } catch let error as MarfaError {
                    return error
                }
            }
            guard case .unauthorized = ended else {
                Issue.record("the watch ended with \(String(describing: ended)), not unauthorized")
                return
            }
            _ = try await folders.sync(directory)
        }

        @Test func aSecondWatchOfAFolderIsRefusedAtOnce() async throws {
            let directory = try await FolderFixture.synced()
            let first = try await folders.watch(directory)
            await #expect {
                try await folders.watch(directory)
            } throws: { error in
                if case .readingHandle = error as? MarfaError { true } else { false }
            }
            try await bounded("the watch to stop", within: 20) { await first.stop() }
        }
    }
}
#endif
