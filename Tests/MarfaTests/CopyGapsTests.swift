import Foundation
import SQLite3
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct AddedFiles {
    @Test func aFileWithNoExtensionIsAnItemOfItsOwn() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let file = try Live.file("no extension", named: "README-\(UUID())")
        let added = try await copy.items.addFile(file)
        let id = try #require(added.item.itemId)
        let item = try #require(try await copy.items.get(id))
        #expect(item.type == "core.file")
        #expect(item.properties["title"]?.string == file.lastPathComponent)
        #expect(added.upload.blob != nil && added.upload.kind == .uploadBlob)
        await copy.close()
    }

    @Test func aNonASCIINameKeepsItsTitleAndGetsItsTags() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let file = try Live.file("héllo", named: "Résumé 写真 \(UUID()).txt")

        let added = try await copy.items.addFile(file, tags: ["scan", "kept"])
        let id = try #require(added.item.itemId)
        let item = try #require(try await copy.items.get(id))
        #expect(item.properties["title"]?.string == file.lastPathComponent)
        #expect(item.tags.sorted() == ["kept", "scan"])
        let tagWrites = try await copy.queue.all().filter { $0.kind == .addTag && $0.itemId == id }
        #expect(tagWrites.count == 2)
        await copy.close()
    }

    @Test func aFileThatIsNotThereQueuesNothing() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        await #expect(throws: (any Error).self) {
            _ = try await copy.items.addFile(URL(filePath: "/nonexistent/\(UUID())"))
        }
        #expect(try await copy.queue.all().isEmpty)
        await copy.close()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ServerCatalogUnreachable {
    @Test func aServerThatCannotBeReachedGivesANetworkError() async throws {
        let server = Server(url: URL(string: "http://127.0.0.1:1")!, key: "unused")
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: server)
        await #expect {
            _ = try await copy.catalog.fromServer()
        } throws: { error in
            if case .network? = error as? MarfaError { true } else { false }
        }
        await copy.close()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ReplacedRefusedCopy {
    private static let refusingSQL = """
        PRAGMA writable_schema = ON;
        UPDATE sqlite_master SET sql = replace(sql, '''replace_metadata'',', '''replace_metadata'', ''merge_metadata'',')
          WHERE type = 'table' AND name = 'queue';
        """

    /// A store whose queue table is not the shape this build reads, with the bytes of one file held beside it.
    static func refusedStore() async throws -> (store: URL, hash: String) {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        let put = try await copy.blobs.put(file: try Live.file("kept bytes \(UUID())"))
        let hash = try #require(put.blob)
        #expect(try await copy.blobs.isHeld(hash))
        await copy.close()
        try OlderStore.execute(store, "DELETE FROM queue;\n" + refusingSQL)
        return (store, hash)
    }

    /// A refused store that holds one write the server has not taken.
    private static func refusedStoreWithAnUnsentWrite() async throws -> URL {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        _ = try await copy.items.create(Draft(type: "core.note", properties: ["body": "unsent"]))
        await copy.close()
        try OlderStore.execute(store, refusingSQL)
        return store
    }

    private static func isWrongSchema(_ error: any Error, unsent: UInt64?) -> Bool {
        if case .wrongSchema(_, _, let count, _)? = error as? MarfaError { count == unsent } else { false }
    }

    @Test func aRefusedStoreIsKeptUnlessTheAppAsksForItToBeReplaced() async throws {
        let (store, _) = try await Self.refusedStore()
        await #expect {
            _ = try await WorkingCopy.open(store: store)
        } throws: { Self.isWrongSchema($0, unsent: 0) }
        await #expect {
            _ = try await WorkingCopy.open(store: store, ifRefused: .keep)
        } throws: { Self.isWrongSchema($0, unsent: 0) }
    }

    @Test func aRefusedStoreIsRebuiltEmptyAndKeepsItsFiles() async throws {
        let (store, hash) = try await Self.refusedStore()

        let copy = try await WorkingCopy.open(store: store, ifRefused: .replace)
        #expect(copy.handle == .writer)
        #expect(try await copy.blobs.isHeld(hash), "the files the old store kept are gone")
        #expect(try await copy.items.list(ListFilters(type: "core.note")).isEmpty)
        _ = try await copy.items.create(Draft(type: "core.note", properties: ["body": "writes again"]))
        await copy.close()
        let reopened = try await WorkingCopy.open(store: store)
        #expect(try await reopened.blobs.isHeld(hash))
        await reopened.close()
    }

    @Test func aBudgetGivenWhenReplacingIsInForceAndKept() async throws {
        let (store, _) = try await Self.refusedStore()
        let copy = try await WorkingCopy.open(store: store, fileBudget: .bytes(bytes: 4_096), ifRefused: .replace)
        #expect(try await copy.blobs.cache().setting == .bytes(bytes: 4_096))
        await copy.close()
        let reopened = try await WorkingCopy.open(store: store)
        #expect(try await reopened.blobs.cache().setting == .bytes(bytes: 4_096))
        await reopened.close()
    }

    @Test func aBudgetTheOldStoreHeldIsKeptWhenNoneIsGiven() async throws {
        let store = temporaryStore()
        let first = try await WorkingCopy.open(store: store, fileBudget: .bytes(bytes: 8_192))
        await first.close()
        try OlderStore.execute(store, "DELETE FROM queue;\n" + Self.refusingSQL)

        let copy = try await WorkingCopy.open(store: store, ifRefused: .replace)
        #expect(try await copy.blobs.cache().setting == .bytes(bytes: 8_192))
        await copy.close()
    }

    @Test func aBudgetThatCannotBeSetAfterAReplacementSaysTheStoreWasReplaced() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        await copy.close()
        await #expect {
            try await copy.applyingOpeningBudget(.keepAll, replaced: true)
        } throws: { error in
            if case .store(let message)? = error as? MarfaError { message.contains("was replaced") } else { false }
        }
        await #expect {
            try await copy.applyingOpeningBudget(.keepAll, replaced: false)
        } throws: { error in
            if case .closed? = error as? MarfaError { true } else { false }
        }
    }

    @Test func aStoreAtAnotherPathDoesNotHoldTheFiles() async throws {
        let (_, hash) = try await Self.refusedStore()
        let copy = try await WorkingCopy.open(store: temporaryStore())
        #expect(!(try await copy.blobs.isHeld(hash)), "files are kept beside their store, so the test proves nothing")
        await copy.close()
    }

    @Test func aStoreThatOpensAsItIsIsNotReplaced() async throws {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        let created = try await copy.items.create(Draft(type: "core.note", properties: ["body": "kept"]))
        let id = try #require(created.itemId)
        await copy.close()

        let reopened = try await WorkingCopy.open(store: store, ifRefused: .replace)
        #expect(reopened.handle == .writer)
        #expect(try await reopened.items.get(id) != nil)
        #expect(try await reopened.queue.all().count == 1)
        await reopened.close()
    }

    @Test func aNewPathIsMadeAsOpenMakesIt() async throws {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store, ifRefused: .replace)
        #expect(copy.handle == .writer)
        #expect(FileManager.default.fileExists(atPath: store.path))
        await copy.close()
    }

    @Test func aRefusedStoreThatHoldsAnUnsentWriteIsLeftAloneWithItsCount() async throws {
        let store = try await Self.refusedStoreWithAnUnsentWrite()

        await #expect {
            _ = try await WorkingCopy.open(store: store, ifRefused: .replace)
        } throws: { Self.isWrongSchema($0, unsent: 1) }
        #expect(try OlderStore.count(store, "SELECT COUNT(*) FROM queue") == 1)

        // The way on, once the person has agreed to lose the write they were shown.
        try await WorkingCopy.remove(store: store, unsent: 1)
        let fresh = try await WorkingCopy.open(store: store, ifRefused: .replace)
        #expect(try await fresh.queue.all().isEmpty)
        await fresh.close()
    }

    @Test func aRefusedStoreAnotherProcessWritesIsLeftAlone() async throws {
        let (store, hash) = try await Self.refusedStore()
        let lock = try HeldWriterLock(store)

        await #expect {
            _ = try await WorkingCopy.open(store: store, ifRefused: .replace)
        } throws: { error in
            if case .readingHandle? = error as? MarfaError { true } else { false }
        }
        lock.release()
        await #expect {
            _ = try await WorkingCopy.open(store: store)
        } throws: { Self.isWrongSchema($0, unsent: 0) }

        // Without the other writer, the same call replaces it, so the refusal above came from the lock.
        let copy = try await WorkingCopy.open(store: store, ifRefused: .replace)
        #expect(try await copy.blobs.isHeld(hash))
        await copy.close()
    }

    @Test func aSecondOpenerOfAStoreThatOpensIsAReaderAndReplacesNothing() async throws {
        let store = temporaryStore()
        let writer = try await WorkingCopy.open(store: store)
        let created = try await writer.items.create(Draft(type: "core.note", properties: ["body": "kept"]))
        let id = try #require(created.itemId)

        let reader = try await WorkingCopy.open(store: store, ifRefused: .replace)
        #expect(reader.handle == .reader)
        #expect(try await reader.items.get(id) != nil)
        await reader.close()
        #expect(try await writer.queue.all().count == 1)
        await writer.close()
    }

    @Test func aRefusedStoreWhoseLockCannotBeWrittenIsLeftAlone() async throws {
        let (store, _) = try await Self.refusedStore()
        let lock = URL(filePath: store.path + ".writer-lock")
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: lock.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path) }

        await #expect {
            _ = try await WorkingCopy.open(store: store, ifRefused: .replace)
        } throws: { error in
            if case .store? = error as? MarfaError { true } else { false }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)
        await #expect {
            _ = try await WorkingCopy.open(store: store)
        } throws: { Self.isWrongSchema($0, unsent: 0) }
    }

    /// A store another server's copy made opens, and keeps its writes; the first call that reaches the server says
    /// it is the wrong one, without sending its request.
    @Test func aStoreFromAnotherServerOpensAndItsFirstServerCallSaysSo() async throws {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        let created = try await copy.items.create(Draft(type: "core.note", properties: ["body": "unsent"]))
        let id = try #require(created.itemId)
        await copy.close()
        try OlderStore.execute(
            store, "INSERT OR REPLACE INTO meta (key, value) VALUES ('server_origin', 'http://127.0.0.1:2');")

        let server = Server(url: URL(string: "http://127.0.0.1:1")!, key: "unused")
        let moved = try await WorkingCopy.open(store: store, server: server, ifRefused: .replace)
        #expect(try await moved.items.get(id) != nil)
        await #expect {
            _ = try await moved.hydrate(types: ["core.note"], tier: .library)
        } throws: { error in
            if case .wrongServer? = error as? MarfaError { true } else { false }
        }
        #expect(try await moved.queue.all().count == 1)
        await moved.close()
    }
}

/// The writer lock of a store, held by another process.
///
/// The core links its own SQLite, and POSIX locks are per process, so a lock taken in this process would not
/// stop it.
private final class HeldWriterLock {
    private let process = Process()
    private let input = Pipe()

    init(_ store: URL) throws {
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/sqlite3")
        process.arguments = [store.path + ".writer-lock"]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data("BEGIN EXCLUSIVE;\n.print held\n".utf8))
        let said = output.fileHandleForReading.availableData
        try #require(String(decoding: said, as: UTF8.self).contains("held"))
    }

    func release() {
        guard process.isRunning else { return }
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    deinit { release() }
}

@Suite(.timeLimit(.minutes(1)))
struct RemovedCopy {
    private static func storeWithUnsent(_ count: Int) async throws -> URL {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        for index in 0..<count {
            _ = try await copy.items.create(Draft(type: "core.note", properties: ["body": .string("unsent \(index)")]))
        }
        await copy.close()
        return store
    }

    @Test func aStoreWhoseUnsentCountMatchesIsRemoved() async throws {
        let store = try await Self.storeWithUnsent(2)
        #expect(FileManager.default.fileExists(atPath: store.path))

        try await WorkingCopy.remove(store: store, unsent: 2)

        #expect(!FileManager.default.fileExists(atPath: store.path))
        let fresh = try await WorkingCopy.open(store: store)
        #expect(try await fresh.items.list(ListFilters(type: "core.note")).isEmpty)
        await fresh.close()
    }

    @Test func aRefusedStoreIsRemovedToo() async throws {
        let (store, _) = try await ReplacedRefusedCopy.refusedStore()
        try await WorkingCopy.remove(store: store, unsent: 0)
        #expect(!FileManager.default.fileExists(atPath: store.path))
    }

    @Test func aMissingStoreIsRemovedWhenNoneAreUnsent() async throws {
        let store = temporaryStore()
        #expect(!FileManager.default.fileExists(atPath: store.path))

        try await WorkingCopy.remove(store: store, unsent: 0)

        #expect(!FileManager.default.fileExists(atPath: store.path))
    }

    @Test func aMissingStoreHasNoUnsentChangesToAgreeTo() async throws {
        let store = temporaryStore()

        await #expect {
            try await WorkingCopy.remove(store: store, unsent: 1)
        } throws: { error in
            guard case .unsentDiffers(_, let unsent, let reported, _)? = error as? MarfaError else {
                return false
            }
            return unsent == 0 && reported == 1
        }
    }

    @Test(arguments: [0, 1, 3] as [UInt64])
    func aDifferentCountLeavesTheStoreAndSaysTheRealOne(agreed: UInt64) async throws {
        let store = try await Self.storeWithUnsent(2)

        await #expect {
            try await WorkingCopy.remove(store: store, unsent: agreed)
        } throws: { error in
            guard case .unsentDiffers(let path, let unsent, let reported, let message)? = error as? MarfaError else {
                return false
            }
            return path.hasSuffix(store.lastPathComponent) && unsent == 2 && reported == agreed && !message.isEmpty
        }
        let kept = try await WorkingCopy.open(store: store)
        #expect(try await kept.queue.all().count == 2)
        await kept.close()
    }

    @Test func aStoreAnotherCopyHasOpenIsLeftAlone() async throws {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        _ = try await copy.items.create(Draft(type: "core.note", properties: ["body": "unsent"]))

        await #expect {
            try await WorkingCopy.remove(store: store, unsent: 1)
        } throws: { error in
            if case .readingHandle? = error as? MarfaError { true } else { false }
        }
        #expect(FileManager.default.fileExists(atPath: store.path))
        #expect(try await copy.queue.all().count == 1)
        await copy.close()
        try await WorkingCopy.remove(store: store, unsent: 1)
        #expect(!FileManager.default.fileExists(atPath: store.path))
    }

    @Test func aReadingHelperKeepsShowingTheCopyUntilItReopens() async throws {
        let store = temporaryStore()
        let writer = try await WorkingCopy.open(store: store)
        let id = try #require(
            try await writer.items.create(Draft(type: "core.note", properties: ["body": "seen"])).itemId)
        await writer.close()
        let reader = try await WorkingCopy.openReader(store: store)

        try await WorkingCopy.remove(store: store, unsent: 1)

        #expect(try await reader.items.get(id) != nil)
        await reader.close()
    }
}
