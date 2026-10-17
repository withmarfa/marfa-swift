import Foundation
import Marfa
import SQLite3
import Testing

/// Properties cross the binding as values.
///
/// Every test works on a copy that has never reached a server, and none reads
/// or writes the keychain.
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

    @Test func propertiesOfEveryJSONKindComeBackAsTheValuesTheyWere() async throws {
        let copy = try await Self.open()
        let properties: JSONObject = [
            "title": "caf\u{e9} \u{1F600} \u{2028} \"quoted\"\n",
            "nothing": nil, "yes": true, "no": false,
            "small": -7, "beyond": .integer(9_007_199_254_740_993), "least": .integer(.min),
            "ratio": 0.1, "tiny": 1e-300,
            "list": [1, [2, [3, ["deep": [nil, "x"]]]]], "empty": [:], "none": [],
        ]
        let id = try await Self.create(copy, properties)
        let held = try #require(try await copy.items.get(id))
        #expect(held.unreadableProperties == nil)
        #expect(held.properties == properties)
        #expect(held.properties["beyond"] == .integer(9_007_199_254_740_993))
        #expect(held.properties["least"] == .integer(.min))
        #expect(held.properties["ratio"] == .number(0.1))
        #expect(held.properties["nothing"] == .null)
        #expect(held.properties["list"]?.array?[1].array?[1].array?[1].object?["deep"]?.array?.count == 2)
        let listed = try #require(try await copy.items.list().first)
        #expect(listed.properties == properties)
        let queued = try #require(try await copy.queue.all().first)
        #expect(queued.body["properties"]?.object == properties)
        await copy.close()
    }

    @Test func aDraftAndAnEditThatNameNoPropertiesCrossAsAnEmptyObject() async throws {
        let copy = try await Self.open()
        let made = try await copy.items.create(Draft(type: "app.test.entry"))
        let id = try #require(made.itemId)
        let held = try #require(try await copy.items.get(id))
        #expect(held.properties.isEmpty)
        #expect(held.unreadableProperties == nil)
        let moved = try await copy.items.update(id, Edit(baseVersion: held.version, tier: .feed))
        #expect(moved.body["properties"] == [:])
        #expect(try #require(try await copy.items.get(id)).tier == .feed)
        await copy.close()
    }

    @Test func theCopyKeepsNumbersAndOrdersKeysAsTheServerDoes() async throws {
        let copy = try await Self.open()
        let id = try await Self.create(copy, ["z": 1, "a": 2, "10": 3, "2": 4, "whole": .number(2.0)])
        let held = try #require(try await copy.items.get(id))
        #expect(held.properties.keys == ["2", "10", "z", "a", "whole"])
        #expect(held.properties["whole"] == .integer(2))
        await copy.close()
    }

    @Test func twoKeysThatDifferOnlyInNormalizationAreTwoKeys() async throws {
        let copy = try await Self.open()
        let composed = "\u{e9}"
        let decomposed = "e\u{301}"
        var properties = JSONObject()
        properties[composed] = "composed"
        properties[decomposed] = "decomposed"
        #expect(properties.count == 2)
        let held = try #require(try await copy.items.get(try await Self.create(copy, properties)))
        #expect(held.properties.count == 2)
        #expect(held.properties[composed] == "composed")
        #expect(held.properties[decomposed] == "decomposed")
        await copy.close()
    }

    @Test func anEditKeepsEveryPropertyItDoesNotNameIncludingOnesTheTypeDoesNotDeclare() async throws {
        let copy = try await Self.open()
        let id = try await Self.create(copy, ["title": "t", "unknown": ["nested": [1, 2.5, "x"]], "also": nil])
        let version = try #require(try await copy.items.get(id)).version
        _ = try await copy.items.update(id, Edit(properties: ["title": "T"], baseVersion: version))
        let merged = try #require(try await copy.items.get(id))
        #expect(merged.properties == ["title": "T", "unknown": ["nested": [1, 2.5, "x"]], "also": nil])

        _ = try await copy.items.update(
            id, Edit(properties: ["title": "U"], replaceProperties: true, baseVersion: version))
        #expect(try #require(try await copy.items.get(id)).properties == ["title": "U"])
        await copy.close()
    }

    @Test func anEdgesPropertiesCrossBothWaysAndAnEdgeEditSendsTheValuesItNames() async throws {
        let copy = try await Self.open()
        let reply = try await Self.create(copy, ["title": "reply"])
        let root = try await Self.create(copy, ["title": "root"])
        let made = try await copy.edges.create(
            from: reply, to: root, type: "in-thread", properties: ["position": 1, "note": ["a", nil]])
        let edge = try #require(try await copy.edges.from(reply).first)
        #expect(edge.properties == ["position": 1, "note": ["a", nil]])
        #expect(edge.unreadableProperties == nil)
        _ = try await copy.edges.update(
            try #require(made.edgeId), EdgeEdit(["position": 2], baseVersion: edge.version))
        #expect(try #require(try await copy.edges.to(root).first).properties["position"] == 2)
        await copy.close()
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

    @Test func aDraftOrEditHoldingAValueTheCoreCannotHoldIsRefusedBeforeAnythingIsQueued() async throws {
        let copy = try await Self.open()
        let id = try await Self.create(copy, ["title": "t"])
        let version = try #require(try await copy.items.get(id)).version
        let repeated = JSONObject(members: [
            JSONMember(key: "a", value: .null), JSONMember(key: "a", value: .bool(true)),
        ])
        let nonFinite: JSONObject = ["rating": [1, .number(.infinity)]]
        for bad in [repeated, nonFinite] {
            let attempts: [(String, @Sendable () async throws -> Void)] = [
                ("create", { _ = try await copy.items.create(Draft(type: "app.test.entry", properties: bad)) }),
                ("update", { _ = try await copy.items.update(id, Edit(properties: bad, baseVersion: version)) }),
                ("extension", { _ = try await copy.extensions.write("acme.x", bad, on: id) }),
            ]
            for (_, attempt) in attempts {
                await #expect {
                    try await attempt()
                } throws: { error in
                    if case MarfaError.invalid = error { true } else { false }
                }
            }
        }
        #expect(try await copy.queue.all().count == 1)
        await copy.close()
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

    /// The server refuses a request body nested more than 64 levels.
    ///
    /// An item's or an edge's properties sit one level down in it, so a value
    /// in a property may nest 62 levels; an extension's body is the object
    /// itself.
    @Test func aWriteNestedPastWhatTheServerReadsIsRefusedInvalidAndOneAtTheLimitIsQueued() async throws {
        @Sendable func nested(_ levels: Int) -> JSONObject {
            ["deep": (0..<levels).reduce(JSONValue.null) { inner, _ in .array([inner]) }]
        }
        let copy = try await Self.open()
        let id = try await Self.create(copy, ["title": "t"])
        let other = try await Self.create(copy, ["title": "other"])
        let version = try #require(try await copy.items.get(id)).version
        let made = try await copy.edges.create(from: id, to: other, type: "references", properties: [:])
        let edgeId = try #require(made.edgeId)
        let queued = try await copy.queue.all().count

        func refused(_ levels: Int) async throws {
            let writes: [(String, @Sendable () async throws -> Void)] = [
                (
                    "create",
                    { _ = try await copy.items.create(Draft(type: "app.test.entry", properties: nested(levels))) }
                ),
                (
                    "update",
                    { _ = try await copy.items.update(id, Edit(properties: nested(levels), baseVersion: version)) }
                ),
                (
                    "edge",
                    {
                        _ = try await copy.edges.create(
                            from: id, to: other, type: "references", properties: nested(levels))
                    }
                ),
                ("edge update", { _ = try await copy.edges.update(edgeId, EdgeEdit(nested(levels), baseVersion: 0)) }),
                ("extension", { _ = try await copy.extensions.write("acme.x", nested(levels + 1), on: id) }),
            ]
            for (_, write) in writes {
                await #expect {
                    try await write()
                } throws: { error in
                    if case MarfaError.invalid = error { true } else { false }
                }
            }
        }
        try await refused(63)
        try await refused(200)
        #expect(try await copy.queue.all().count == queued, "a refused write was queued")

        _ = try await copy.items.create(Draft(type: "app.test.entry", properties: nested(62)))
        _ = try await copy.items.create(Draft(type: "app.test.entry", properties: nested(61)))
        _ = try await copy.items.update(id, Edit(properties: nested(62), baseVersion: version))
        _ = try await copy.edges.update(edgeId, EdgeEdit(nested(62), baseVersion: 0))
        _ = try await copy.extensions.write("acme.x", nested(63), on: id)
        #expect(try await copy.queue.all().count == queued + 5)
        await copy.close()
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
