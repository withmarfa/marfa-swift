import Foundation
import Marfa
import SQLite3
import Testing

/// Properties cross the binding as values.
///
/// Every test works on a copy that has never reached a server, and none reads
/// or writes the keychain. These need a store damaged behind the copy's back,
/// so they stay with the real copy; the rest are held to the fake copy as well,
/// in `PropertyValuesOffline`.
@Suite(.timeLimit(.minutes(1)))
struct PropertyValues {
    static let entry: JSONObject = [
        "id": "app.test.entry", "fields": ["title": ["type": "string"]],
    ]

    /// A copy with an app type that declares one field, so a property it does
    /// not declare is one the app has never seen.
    static func open(_ store: URL = temporaryStore()) async throws -> WorkingCopy {
        let copy = try await WorkingCopy.open(store: store)
        try await copy.declareTypes([entry])
        return copy
    }

    static func create(_ copy: WorkingCopy, _ properties: JSONObject) async throws -> String {
        try #require(try await copy.items.create(Draft(type: "app.test.entry", properties: properties)).itemId)
    }

    @Test func aRowWhoseStoredPropertiesCannotBeReadIsFlaggedAndDoesNotFailAListOrASearch() async throws {
        let store = temporaryStore()
        let copy = try await Self.open(store)
        var ids: [String] = []
        for title in ["kept zebra", "torn zebra", "bare zebra"] {
            ids.append(try await Self.create(copy, ["title": .string(title)]))
        }
        await copy.close()
        try Self.damage(store, "UPDATE items SET properties = '{\"title\":' WHERE id = '\(ids[1])'")
        try Self.damage(store, "UPDATE items SET properties = '[1]' WHERE id = '\(ids[2])'")

        let reopened = try await WorkingCopy.open(store: store)
        let listed = try await reopened.items.list(ListFilters(), sort: Sort(field: .createdAt, direction: .ascending))
        #expect(listed.map(\.id) == ids)
        #expect(listed[0].unreadableProperties == nil)
        #expect(listed[0].properties == ["title": "kept zebra"])
        for damaged in listed.dropFirst() {
            #expect(damaged.properties.isEmpty)
            #expect(damaged.unreadableProperties != nil)
            #expect(damaged.title == nil)
            #expect(damaged.state == .active)
        }
        let hits = try await reopened.search("zebra")
        #expect(hits.count == 3)
        #expect(hits.filter { $0.item.unreadableProperties != nil }.count == 2)
        // A damaged row matches no property condition, so a filtered list and
        // a filtered search leave it out and still answer.
        let filter = #"properties.title eq "kept zebra""#
        #expect(try await reopened.items.list(ListFilters(filter: filter)).map(\.id) == [ids[0]])
        #expect(try await reopened.search("zebra", filters: SearchFilters(filter: filter)).map(\.item.id) == [ids[0]])
        let torn = try #require(try await reopened.items.get(ids[1]))
        #expect(torn.unreadableProperties != nil)
        #expect(try await reopened.status().items == 3)
        await reopened.close()
    }

    @Test func aDamagedEdgeIsFlaggedAndItsSiblingsStillRead() async throws {
        let store = temporaryStore()
        let copy = try await Self.open(store)
        let root = try await Self.create(copy, ["title": "root"])
        let first = try await Self.create(copy, ["title": "first"])
        let second = try await Self.create(copy, ["title": "second"])
        _ = try await copy.edges.create(from: first, to: root, type: "in-thread", properties: ["position": 1])
        let damagedId = try #require(
            try await copy.edges.create(from: second, to: root, type: "in-thread", properties: ["position": 2]).edgeId)
        await copy.close()
        try Self.damage(store, "UPDATE edges SET properties = '{' WHERE id = '\(damagedId)'")

        let reopened = try await WorkingCopy.open(store: store)
        let held = try await reopened.edges.to(root)
        #expect(held.count == 2)
        let damaged = try #require(held.first { $0.id == damagedId })
        #expect(damaged.properties.isEmpty)
        #expect(damaged.unreadableProperties != nil)
        let sound = try #require(held.first { $0.id != damagedId })
        #expect(sound.properties == ["position": 1])
        #expect(sound.unreadableProperties == nil)
        await reopened.close()
    }

    @Test func anEmbedIntoAHostWhoseStoredPropertiesCannotBeReadWritesNoBodyOverThem() async throws {
        let store = temporaryStore()
        let copy = try await Self.open(store)
        let host = try await Self.create(copy, ["title": "host"])
        let sound = try await Self.create(copy, ["title": "sound", "body": "kept"])
        let file = FileManager.default.temporaryDirectory.appending(path: "clip-\(UUID()).mov")
        try Data("bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        // The witness: the same embed into a readable host queues a write of its body.
        _ = try await copy.items.embed(file: file, in: sound)
        #expect(try await copy.queue.all().contains { $0.kind == .updateItem })
        await copy.close()
        try Self.damage(store, "UPDATE items SET properties = '{' WHERE id = '\(host)'")

        let reopened = try await WorkingCopy.open(store: store)
        do {
            _ = try await reopened.items.embed(file: file, in: host)
            Issue.record("the embed was written over a body that could not be read")
        } catch {
            // Refused before or after the file was attached; either way no write of the body is queued.
        }
        #expect(try await reopened.queue.all().filter { $0.kind == .updateItem }.count == 1)
        await reopened.close()
    }

    /// Writes to the store behind the copy's back, as something else that holds
    /// the file would.
    static func damage(_ store: URL, _ statement: String) throws {
        var database: OpaquePointer?
        try #require(sqlite3_open(store.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        try #require(sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK)
    }
}
