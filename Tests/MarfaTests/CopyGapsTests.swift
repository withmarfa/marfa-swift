import Foundation
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
    /// A store whose queue table is not the shape this build reads, with the bytes of one file held beside it.
    static func refusedStore() async throws -> (store: URL, hash: String) {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        let put = try await copy.blobs.put(file: try Live.file("kept bytes \(UUID())"))
        let hash = try #require(put.blob)
        #expect(try await copy.blobs.isHeld(hash))
        await copy.close()
        try OlderStore.execute(
            store,
            """
            DELETE FROM queue;
            PRAGMA writable_schema = ON;
            UPDATE sqlite_master SET sql = replace(sql, '''replace_metadata'',', '''replace_metadata'', ''merge_metadata'',')
              WHERE type = 'table' AND name = 'queue';
            """)
        return (store, hash)
    }

    @Test func aRefusedStoreIsRebuiltEmptyAndKeepsItsFiles() async throws {
        let (store, hash) = try await Self.refusedStore()
        await #expect {
            _ = try await WorkingCopy.open(store: store)
        } throws: { error in
            if case .wrongSchema? = error as? MarfaError { true } else { false }
        }

        let copy = try await WorkingCopy.replaceRefused(store: store)
        #expect(try await copy.blobs.isHeld(hash), "the files the old store kept are gone")
        #expect(try await copy.items.list(ListFilters(type: "core.note")).isEmpty)
        _ = try await copy.items.create(Draft(type: "core.note", properties: ["body": "writes again"]))
        await copy.close()
        let reopened = try await WorkingCopy.open(store: store)
        #expect(try await reopened.blobs.isHeld(hash))
        await reopened.close()
    }

    @Test func aStoreAtAnotherPathDoesNotHoldTheFiles() async throws {
        let (_, hash) = try await Self.refusedStore()
        let copy = try await WorkingCopy.open(store: temporaryStore())
        #expect(!(try await copy.blobs.isHeld(hash)), "files are kept beside their store, so the test proves nothing")
        await copy.close()
    }

    @Test func aStoreThatOpensAsItIsIsLeftAlone() async throws {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        let created = try await copy.items.create(Draft(type: "core.note", properties: ["body": "kept"]))
        let id = try #require(created.itemId)
        await copy.close()

        await #expect {
            _ = try await WorkingCopy.replaceRefused(store: store)
        } throws: { error in
            if case .invalid? = error as? MarfaError { true } else { false }
        }
        let reopened = try await WorkingCopy.open(store: store)
        #expect(try await reopened.items.get(id) != nil)
        await reopened.close()
    }

    @Test func aRefusedStoreThatHoldsAnUnsentWriteIsLeftAlone() async throws {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        _ = try await copy.items.create(Draft(type: "core.note", properties: ["body": "unsent"]))
        await copy.close()
        try OlderStore.execute(
            store,
            """
            PRAGMA writable_schema = ON;
            UPDATE sqlite_master SET sql = replace(sql, '''replace_metadata'',', '''replace_metadata'', ''merge_metadata'',')
              WHERE type = 'table' AND name = 'queue';
            """)

        await #expect {
            _ = try await WorkingCopy.replaceRefused(store: store)
        } throws: { error in
            if case .wrongSchema(_, _, let unsent, _)? = error as? MarfaError { unsent == 1 } else { false }
        }
        #expect(try OlderStore.count(store, "SELECT COUNT(*) FROM queue") == 1)
    }
}
