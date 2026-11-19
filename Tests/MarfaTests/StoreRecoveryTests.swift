import Foundation
import Marfa
import SQLite3
import Testing

/// What a person is offered for a store `open` refuses: to see what it holds, to keep it aside, or to give it up.
@Suite(.timeLimit(.minutes(1)))
struct StoreRecovery {
    /// A store with one note and one tag unsent, then closed.
    private static func storeWithUnsentWrites() async throws -> (URL, String) {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        let id = try #require(
            try await copy.items.create(Draft(type: "core.note", properties: ["body": "kept"])).itemId)
        _ = try await copy.tags.add("kept", to: id)
        await copy.close()
        return (store, id)
    }

    /// Writes over the first page, so SQLite no longer reads the file as a database.
    private static func damage(_ store: URL) throws {
        let handle = try FileHandle(forWritingTo: store)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(repeating: 0x5A, count: 4096))
    }

    /// Overwrites the page that holds one table's rows, so SQLite still reads the file but not that table.
    private static func damage(_ store: URL, table: String) throws {
        var database: OpaquePointer?
        try #require(sqlite3_open_v2(store.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(database) }
        func number(_ sql: String) throws -> Int {
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            try #require(sqlite3_step(statement) == SQLITE_ROW)
            return Int(sqlite3_column_int64(statement, 0))
        }
        let size = try number("PRAGMA page_size")
        let root = try number("SELECT rootpage FROM sqlite_master WHERE type = 'table' AND name = '\(table)'")
        let handle = try FileHandle(forWritingTo: store)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64((root - 1) * size))
        try handle.write(contentsOf: Data(repeating: 0xA5, count: size))
    }

    @Test func aStoreDamagedOutsideItsQueueStillListsItsUnsentWritesAndCarriesThemWhenSetAside() async throws {
        let (store, id) = try await Self.storeWithUnsentWrites()
        try Self.damage(store, table: "items")
        await #expect(throws: Marfa.MarfaError.self) { try await WorkingCopy.check(store: store) }

        // The person can see what is unsent before choosing.
        let unsent = try await WorkingCopy.unsentWrites(in: store)
        #expect(unsent.writes.count == 2)
        #expect(unsent.writes.allSatisfy { $0.itemId == id })
        #expect(unsent.writes.map(\.kind).sorted() == ["add_tag", "create_item"])

        let result = try await WorkingCopy.setAsideDamaged(store: store)
        #expect(result.carried > 0, "\(result)")
        #expect(FileManager.default.fileExists(atPath: result.setAside))
        let reopened = try await WorkingCopy.open(store: store)
        #expect(try await reopened.queue.all().isEmpty == false)
        await reopened.close()
        try await WorkingCopy.remove(store: store, confirming: try await WorkingCopy.unsentWrites(in: store))
        try? FileManager.default.removeItem(atPath: result.setAside)
    }

    @Test func aWholeStorePassesTheCheckAndListsItsUnsentWritesWithoutChangingThem() async throws {
        let (store, id) = try await Self.storeWithUnsentWrites()
        try await WorkingCopy.check(store: store)
        let unsent = try await WorkingCopy.unsentWrites(in: store)
        #expect(unsent.writes.count == 2)
        #expect(unsent.writes.allSatisfy { $0.itemId == id })
        #expect(unsent.writes.map(\.kind).sorted() == ["add_tag", "create_item"])
        try await WorkingCopy.remove(store: store, confirming: unsent)
        #expect(!FileManager.default.fileExists(atPath: store.path))
    }

    @Test func removingLosingAllRefusesAStoreWhoseUnsentWritesReadAndCountsThem() async throws {
        let (store, _) = try await Self.storeWithUnsentWrites()
        await #expect {
            try await WorkingCopy.removeLosingAll(store: store)
        } throws: { error in
            guard case Marfa.MarfaError.unsentDiffers(let path, let unsent, _) = error else { return false }
            return path.hasSuffix(store.lastPathComponent) && unsent == 2
        }
        #expect(FileManager.default.fileExists(atPath: store.path), "the refused removal left the store")

        let unsent = try await WorkingCopy.unsentWrites(in: store)
        #expect(unsent.writes.count == 2)
        try await WorkingCopy.remove(store: store, confirming: unsent)
        #expect(!FileManager.default.fileExists(atPath: store.path))
    }

    @Test func aDamagedStoreSaysWhetherASetAsideStopped() async throws {
        let (store, _) = try await Self.storeWithUnsentWrites()
        try Self.damage(store)
        func stopped() async throws -> Bool {
            do {
                try await WorkingCopy.check(store: store)
            } catch Marfa.MarfaError.storeDamaged(_, _, _, let setAsideStopped, _) {
                return setAsideStopped
            }
            Issue.record("the damaged store passed the check")
            return false
        }
        #expect(try await stopped() == false)
        let carrying = URL(fileURLWithPath: store.path + ".carrying")
        try Data().write(to: carrying)
        defer { try? FileManager.default.removeItem(at: carrying) }
        #expect(try await stopped() == true)
        // The flag is the app's cue to offer no removal.
        await #expect(throws: Marfa.MarfaError.self) { try await WorkingCopy.removeLosingAll(store: store) }
        #expect(FileManager.default.fileExists(atPath: store.path))
        try FileManager.default.removeItem(at: carrying)
        try await WorkingCopy.removeLosingAll(store: store)
    }

    @Test func aDamagedStoreFailsTheCheckAndTheOpenNamingTheStore() async throws {
        let (store, _) = try await Self.storeWithUnsentWrites()
        try Self.damage(store)
        for call in [
            { try await WorkingCopy.check(store: store) },
            { _ = try await WorkingCopy.open(store: store) },
        ] as [@Sendable () async throws -> Void] {
            await #expect {
                try await call()
            } throws: { error in
                guard case Marfa.MarfaError.storeDamaged(let path, _, _, _, _) = error else { return false }
                return path.hasSuffix(store.lastPathComponent)
            }
        }
        try await WorkingCopy.removeLosingAll(store: store)
        #expect(!FileManager.default.fileExists(atPath: store.path))
    }

    @Test func aStoreThatOpensAsItIsIsNotSetAside() async throws {
        let (store, _) = try await Self.storeWithUnsentWrites()
        await #expect {
            _ = try await WorkingCopy.setAsideDamaged(store: store)
        } throws: { error in
            if case Marfa.MarfaError.invalid = error { return true }
            return false
        }
        try await WorkingCopy.remove(store: store, confirming: try await WorkingCopy.unsentWrites(in: store))
    }

    @Test func aStoreWhoseFirstPageIsGoneIsKeptAsideAndAFreshOneTakesItsPlace() async throws {
        let (store, _) = try await Self.storeWithUnsentWrites()
        try Self.damage(store)
        let result = try await WorkingCopy.setAsideDamaged(store: store)
        #expect(result.setAside.contains(".damaged-"))
        #expect(FileManager.default.fileExists(atPath: result.setAside))
        #expect(
            result.carried == 0 && result.unread == 0 && !result.whole,
            "a queue that cannot be read is not reported whole")
        try await WorkingCopy.check(store: store)
        let reopened = try await WorkingCopy.open(store: store)
        await reopened.close()
        try await WorkingCopy.removeLosingAll(store: store)
        try? FileManager.default.removeItem(atPath: result.setAside)
    }
}
