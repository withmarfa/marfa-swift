import Foundation
import MarfaCore
import Testing

@testable import Marfa

/// The reads an app makes of a whole copy and of what changed in it, on a copy that never reached a server.
@Suite(.timeLimit(.minutes(1)))
struct CopyReads {
    static func note(_ title: String, body: String = "", in copy: WorkingCopy) async throws -> String {
        try #require(
            try await copy.items.create(
                Draft(type: "core.note", properties: ["title": .string(title), "body": .string(body)])
            ).itemId)
    }

    static func named(_ changes: Marfa.CopyChanges) throws -> ChangedRows {
        guard case .named(let rows, _) = changes else {
            Issue.record("expected the changes named one by one, got \(changes)")
            throw CancellationError()
        }
        return rows
    }

    @Test func linksInManyItemsAreEachWhatTheOneItemReadAnswersLeavingOutTheBinAndTheAbsent() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let target = try await Self.note("Target", in: copy)
        let linking = try await Self.note("Linking", body: "See [[\(target)]] and [[Nowhere]].", in: copy)
        let plain = try await Self.note("Plain", body: "No links.", in: copy)
        let binned = try await Self.note("Binned", body: "[[\(target)]]", in: copy)
        _ = try await copy.items.delete(binned)

        let read = try await copy.items.links(in: [linking, plain, binned, "absent", target])
        #expect(Set(read.keys) == [linking, plain, target])
        for id in [linking, plain, target] {
            #expect(read[id] == (try await copy.items.links(in: id)))
        }
        #expect(read[linking]?.links.map(\.name) == [target, "Nowhere"])
        #expect(read[linking]?.links.first?.target == .item(id: target))
        #expect(read[plain] == BodyLinks())
        #expect(try await copy.items.links(in: [String]()).isEmpty)
        await copy.close()
    }

    @Test func noCursorAnswersEverythingAndItsNextNamesWhatChangedAfter() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let first = try await copy.changes(since: nil)
        guard case .everything(let start) = first else {
            Issue.record("a first read named changes: \(first)")
            return
        }
        #expect(first.next == start)

        let a = try await Self.note("a", in: copy)
        let b = try await Self.note("b", in: copy)
        let afterNotes = try await copy.changes(since: start)
        #expect(try Self.named(afterNotes) == ChangedRows(items: [a, b].sorted()))

        let quiet = try await copy.changes(since: afterNotes.next)
        #expect(try Self.named(quiet).isEmpty)
        #expect(quiet.next == afterNotes.next)

        let edge = try #require(try await copy.edges.create(from: a, to: b, type: "about").edgeId)
        let withEdge = try Self.named(try await copy.changes(since: quiet.next))
        #expect(withEdge.edges == [edge])
        #expect(withEdge.removedEdges.isEmpty)
        await copy.close()
    }

    @Test func aRemovedEdgeAndABinnedItemAreNamedAsRemovedAndHeld() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let a = try await Self.note("a", in: copy)
        let b = try await Self.note("b", in: copy)
        let edge = try #require(try await copy.edges.create(from: a, to: b, type: "about").edgeId)
        let cursor = try await copy.changes(since: nil).next

        _ = try await copy.edges.delete(edge)
        _ = try await copy.items.delete(b)
        let changed = try Self.named(try await copy.changes(since: cursor))
        #expect(changed.removedEdges == [edge])
        #expect(changed.edges.isEmpty)
        #expect(changed.items.contains(b), "an item in the bin is still held")
        #expect(changed.removedItems.isEmpty)
        #expect(try await copy.items.get(changed.items).map(\.id).contains(b) == false)
        #expect(
            try await copy.items.get(changed.items, includingBin: true).contains { $0.id == b && $0.state == .trashed })
        await copy.close()
    }

    @Test func moreChangesThanMostAnswerEverything() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let cursor = try await copy.changes(since: nil).next
        for title in ["a", "b", "c"] { _ = try await Self.note(title, in: copy) }

        guard case .everything = try await copy.changes(since: cursor, most: 2) else {
            Issue.record("three changes were named under a limit of two")
            await copy.close()
            return
        }
        #expect(try Self.named(try await copy.changes(since: cursor, most: 3)).items.count == 3)
        await copy.close()
    }

    @Test func aCursorFromAnotherStoreAnswersEverythingAndTextThatIsNotOneIsRefused() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let other = try await WorkingCopy.open(store: temporaryStore())
        let elsewhere = try await other.changes(since: nil).next
        _ = try await Self.note("a", in: copy)

        guard case .everything = try await copy.changes(since: elsewhere) else {
            Issue.record("another store's cursor was followed")
            await copy.close()
            await other.close()
            return
        }
        await #expect(
            performing: { _ = try await copy.changes(since: ChangeCursor(rawValue: "not a cursor")) },
            throws: { error in if case .invalid? = error as? Marfa.MarfaError { true } else { false } })
        await copy.close()
        await other.close()
    }

    @Test func aCursorKeptAsItsRawValueAndCodedCarriesOn() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let cursor = try await copy.changes(since: nil).next
        let kept = try JSONDecoder().decode(ChangeCursor.self, from: JSONEncoder().encode(cursor))
        #expect(kept == cursor)
        let a = try await Self.note("a", in: copy)
        #expect(try Self.named(try await copy.changes(since: ChangeCursor(rawValue: kept.rawValue))).items == [a])
        await copy.close()
    }
}

/// The listing a read of many items answers crosses from the core as one buffer the package reads back.
@Suite(.timeLimit(.minutes(1)))
struct PackedListing {
    /// The bytes `the_layout_of_a_plain_item_is_the_one_the_swift_package_reads` in the core's `packed.rs` holds.
    static let agreed: [UInt8] = {
        var bytes: [UInt8] = [1, 0, 0, 0, 1, 0, 0, 0]
        bytes += [2, 0, 0, 0] + Array("id".utf8)
        bytes += [9, 0, 0, 0] + Array("core.note".utf8)
        bytes += [1, 0, 0, 0, 1, 0, 0, 0] + Array("k".utf8) + [3, 1, 0, 0, 0, 0, 0, 0, 0]
        bytes += [0, 0]
        bytes += withUnsafeBytes(of: Int64.max.littleEndian, Array.init)
        bytes += withUnsafeBytes(of: Int64(2).littleEndian, Array.init)
        bytes += [6, 0, 0, 0] + Array("device".utf8)
        bytes += [0]
        for at in ["2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z", "2026-01-03T00:00:00Z"] {
            bytes += [20, 0, 0, 0] + Array(at.utf8)
        }
        bytes += [0, 0, 0, 0]
        bytes += [0, 0, 0, 0, 0]
        return bytes
    }()

    static let plain = Item(
        id: "id", type: "core.note", properties: ["k": 1], state: .active, tier: nil, version: .max,
        schemaVersion: 2, source: "device", sourceId: nil, occurredAt: "2026-01-01T00:00:00Z",
        createdAt: "2026-01-02T00:00:00Z", updatedAt: "2026-01-03T00:00:00Z", tags: [])

    static let full = Item(
        id: "a", type: "core.note",
        properties: [
            "null": .null, "no": false, "yes": true, "integer": .integer(.min), "number": -0.5,
            "text": "é ✓ \u{0}", "array": [1, []], "object": ["": .null],
        ],
        state: .revoked, tier: .feed, version: 7, schemaVersion: 2, source: "device", sourceId: "source",
        occurredAt: "2026-01-01T00:00:00Z", createdAt: "2026-01-02T00:00:00Z", updatedAt: "2026-01-03T00:00:00Z",
        tags: ["x", ""], captureLatitude: 51.5, captureLongitude: -0.12, title: "Title", body: "",
        unreadableProperties: "why")

    /// The bytes `the_layout_of_a_full_item_is_the_one_the_swift_package_reads` in the core's `packed.rs` holds.
    static let fullBytes: [UInt8] = {
        func text(_ text: String) -> [UInt8] {
            withUnsafeBytes(of: UInt32(text.utf8.count).littleEndian, Array.init) + Array(text.utf8)
        }
        func bits<T>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value, Array.init) }
        var bytes: [UInt8] = [1, 0, 0, 0, 1, 0, 0, 0]
        bytes += text("a") + text("core.note")
        bytes += [8, 0, 0, 0]
        bytes += text("null") + [0]
        bytes += text("no") + [1]
        bytes += text("yes") + [2]
        bytes += text("integer") + [3] + bits(Int64.min.littleEndian)
        bytes += text("number") + [4] + bits((-0.5).bitPattern.littleEndian)
        bytes += text("text") + [5] + text("é ✓ \u{0}")
        bytes += text("array") + [6, 2, 0, 0, 0, 3, 1, 0, 0, 0, 0, 0, 0, 0, 6, 0, 0, 0, 0]
        bytes += text("object") + [7, 1, 0, 0, 0, 0, 0, 0, 0, 0]
        bytes += [3, 2]
        bytes += bits(Int64(7).littleEndian) + bits(Int64(2).littleEndian)
        bytes += text("device") + [1] + text("source")
        for at in ["2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z", "2026-01-03T00:00:00Z"] { bytes += text(at) }
        bytes += [2, 0, 0, 0] + text("x") + text("")
        bytes += [1] + bits((51.5).bitPattern.littleEndian)
        bytes += [1] + bits((-0.12).bitPattern.littleEndian)
        bytes += [1] + text("Title") + [1] + text("") + [1] + text("why")
        return bytes
    }()

    static func refused(_ bytes: [UInt8]) -> Bool {
        do {
            _ = try PackedRows.items(Data(bytes))
            return false
        } catch {
            if case .decoding = error { return true }
            return false
        }
    }

    @Test func theAgreedBytesReadAsTheItemAndTheItemPacksAsThem() throws {
        #expect(try PackedRows.items(Data(Self.agreed)) == [Self.plain])
        #expect(PackedRows.pack([Self.plain]) == Data(Self.agreed))
        #expect(try PackedRows.items(Data(Self.fullBytes)) == [Self.full])
        #expect(PackedRows.pack([Self.full]) == Data(Self.fullBytes))
    }

    @Test func aListingOfAnotherFormatIsRefusedNamingBoth() {
        var other = Self.agreed
        other[0] = 2
        do {
            _ = try PackedRows.items(Data(other))
            Issue.record("a listing of format 2 was read")
        } catch {
            if case .decoding(let message) = error {
                #expect(message.contains("format 2, where this package reads format 1"), "\(message)")
            } else {
                Issue.record("\(error)")
            }
        }
    }

    @Test func everyFieldAndValueReadsBackAsItWasPacked() throws {
        var archived = Self.plain
        archived.state = .archived
        archived.tier = .library
        var trashed = Self.plain
        trashed.state = .trashed
        let items = [Self.full, Self.plain, archived, trashed]
        #expect(try PackedRows.items(PackedRows.pack(items)) == items)
        #expect(try PackedRows.items(PackedRows.pack([])) == [])
        let listing = Listing(items: items, completeness: .partial)
        #expect(try listing.answer == Rows(items, completeness: .partial))
    }

    @Test func aBufferThatIsNotAListingIsRefusedNotTrusted() {
        let packed = Array(PackedRows.pack([Self.full]))
        #expect(Self.refused([]))
        for length in 1..<packed.count {
            #expect(Self.refused(Array(packed.prefix(length))), "cut at \(length)")
        }
        #expect(Self.refused(packed + [0]))
        #expect(Self.refused([1, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF]), "a count far beyond the bytes")

        var badState = Self.agreed
        badState[8 + 6 + 13 + 18] = 4
        #expect(Self.refused(badState))
        var badValue = Self.agreed
        badValue[8 + 6 + 13 + 9] = 8
        #expect(Self.refused(badValue))
    }

    @Test func aValueNestedBeyondTheLimitIsRefused() {
        /// Properties nested `depth` arrays deep, inside the properties object.
        func nested(_ depth: Int) -> [UInt8] {
            var item = Array(PackedRows.pack([Self.plain]))
            // The value of `k`, one integer, becomes `depth` arrays, each holding the next, around null.
            let at = 8 + 6 + 13 + 9
            var value: [UInt8] = []
            for _ in 0..<depth { value += [6, 1, 0, 0, 0] }
            value.append(0)
            item.replaceSubrange(at..<at + 9, with: value)
            return item
        }
        #expect(!Self.refused(nested(PackedRows.Reader.depthLimit - 1)))
        #expect(Self.refused(nested(PackedRows.Reader.depthLimit)))
        #expect(Self.refused(nested(10_000)))
    }

    @Test func aRowNestedPastTheLimitIsListedUnreadableAsAReadOfItAnswers() async throws {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        let kept = try #require(
            try await copy.items.create(Draft(type: "core.note", properties: ["title": "Kept"])).itemId)
        let deep = try #require(
            try await copy.items.create(Draft(type: "core.note", properties: ["title": "Deep"])).itemId)
        await copy.close()
        let nested = String(repeating: "[", count: 69) + "null" + String(repeating: "]", count: 69)
        try PropertyValues.damage(store, "UPDATE items SET properties = '{\"deep\":\(nested)}' WHERE id = '\(deep)'")

        let reopened = try await WorkingCopy.open(store: store)
        let listed = try await reopened.items.list(ListFilters())
        #expect(Set(listed.map(\.id)) == [kept, deep])
        let held = try #require(listed.first { $0.id == deep })
        #expect(held.properties.members.isEmpty)
        #expect(held.unreadableProperties != nil)
        #expect(try await reopened.items.get(deep) == held)
        await reopened.close()
    }

    @Test func aListingFromTheCoreReadsAsEachItemReadAlone() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        var ids: [String] = []
        let drafts = [
            Draft(type: "core.note", properties: ["title": "Plain", "body": "Text"]),
            Draft(
                type: "core.note",
                properties: [
                    "title": "Every value", "body": "", "nothing": .null, "flag": true,
                    "count": .integer(-9_007_199_254_740_991),
                    "ratio": 0.25, "list": [1, "two", [], [:]], "nested": ["inner": ["deep": false]],
                    "text": "é ✓ \u{1F600}",
                ],
                tags: ["b", "a"], tier: .feed, sourceId: "elsewhere-1", occurredAt: "2025-02-03T04:05:06.007Z",
                captureLatitude: 51.5, captureLongitude: -0.125),
            Draft(type: "core.note", properties: ["title": "Archived"]),
            Draft(type: "core.note", properties: ["title": "Binned"]),
        ]
        for draft in drafts { ids.append(try #require(try await copy.items.create(draft).itemId)) }
        _ = try await copy.items.transition(ids[2], to: .archived)
        _ = try await copy.items.delete(ids[3])

        let listed = try await copy.items.list(ListFilters(allStates: true))
        #expect(Set(listed.map(\.id)) == Set(ids))
        for item in listed where item.id != ids[3] {
            #expect(try await copy.items.get(item.id) == item)
        }
        let binned = try #require(listed.first { $0.id == ids[3] })
        #expect(binned.state == .trashed)
        let every = try #require(listed.first { $0.id == ids[1] })
        #expect(every.tags == ["a", "b"] && every.tier == .feed && every.sourceId == "elsewhere-1")
        #expect(every.captureLatitude == 51.5 && every.captureLongitude == -0.125)
        await copy.close()
    }
}
