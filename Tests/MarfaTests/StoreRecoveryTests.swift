import Foundation
import Marfa
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

    @Test func aWholeStorePassesTheCheckAndListsItsUnsentWritesWithoutChangingThem() async throws {
        let (store, id) = try await Self.storeWithUnsentWrites()
        try await WorkingCopy.check(store: store)
        let unsent = try await WorkingCopy.unsentWrites(in: store)
        #expect(unsent.count == 2)
        #expect(unsent.allSatisfy { $0.itemId == id })
        #expect(unsent.map(\.kind).sorted() == ["add_tag", "create_item"])
        try await WorkingCopy.removeLosingAll(store: store)
        #expect(!FileManager.default.fileExists(atPath: store.path))
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
                guard case Marfa.MarfaError.storeDamaged(let path, _, _, _) = error else { return false }
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
        try await WorkingCopy.removeLosingAll(store: store)
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
