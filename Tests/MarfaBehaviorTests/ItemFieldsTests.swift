#if DEBUG
import Foundation
import Marfa
import Testing

/// The fields a create, an edit and a list carry beyond the basics, on a copy that never reached a server.
@Suite(.timeLimit(.minutes(1)))
struct ItemFieldsOffline {
    static func note(_ copy: WorkingCopy, _ title: String, _ more: (inout Draft) -> Void = { _ in }) async throws
        -> Item
    {
        var draft = Draft(type: "core.note", properties: ["title": .string(title), "body": "b"])
        more(&draft)
        let id = try #require(try await copy.items.create(draft).itemId)
        return try #require(try await copy.items.get(id))
    }

    static func refused(_ code: String) -> (any Error) -> Bool {
        { error in
            if case .validation(let given, _)? = error as? MarfaError { given == code } else { false }
        }
    }

    @Test(arguments: CopyKind.allCases)
    func aCreateCarriesItsStateLocationAndEdgesInOneWriteAndShowsThem(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let target = try await Self.note(copy, "target")
        let made = try await Self.note(copy, "made") {
            $0.state = .archived
            $0.captureLatitude = 51.5
            $0.captureLongitude = -0.12
            $0.edges = ["references": [target.id]]
        }
        #expect(made.state == .archived)
        #expect(made.captureLatitude == 51.5 && made.captureLongitude == -0.12)
        let shown = try await copy.edges.from(made.id)
        #expect(shown.map(\.targetId) == [target.id] && shown.map(\.edgeType) == ["references"])
        let creates = try await copy.queue.all().filter { $0.itemId == made.id }
        #expect(creates.map(\.kind) == [.createItem])
        #expect(creates[0].body["state"] == "archived")
        #expect(creates[0].body["capture_latitude"] == 51.5)
        #expect(creates[0].body["edges"]?.object == ["references": [.string(target.id)]])
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aCreateDrawnToAnUnsentCreateWaitsForIt(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let first = try #require(
            try await copy.items.create(Draft(type: "core.note", properties: ["body": "a"])).itemId)
        let second = try await copy.items.create(
            Draft(type: "core.note", properties: ["body": "b"], edges: ["references": [first]]))
        let firstCreate = try #require(try await copy.queue.all().first { $0.itemId == first })
        #expect(second.dependsOn == [firstCreate.id])
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEmptyEdgeListMakesNoEdgeAndSendsNone(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let plain = try await copy.items.create(
            Draft(type: "core.note", properties: ["body": "a"], edges: ["references": []]))
        #expect(plain.body["edges"] == nil)
        #expect(try await copy.edges.from(try #require(plain.itemId)).isEmpty)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aCreateTheServerWouldRefuseIsRefusedBeforeAnythingIsQueued(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let drafts = [
            Draft(type: "core.note", properties: ["body": "a"], state: .revoked),
            Draft(type: "core.note", properties: ["body": "a"], captureLatitude: .nan, captureLongitude: 0),
            Draft(type: "core.note", properties: ["body": "a"], edges: ["references": ["not-an-id"]]),
        ]
        for draft in drafts {
            await #expect(
                performing: { _ = try await copy.items.create(draft) },
                throws: { error in
                    if case .validation? = error as? MarfaError { true } else { false }
                })
        }
        #expect(try await copy.queue.all().isEmpty)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func clearingTheOwnTimeOfAnUnsentCreateSendsNoneAndShowsTheQueuedTime(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let held = try await Self.note(copy, "timed") { $0.occurredAt = "2026-01-02T03:04:05.000Z" }
        #expect(held.occurredAt == "2026-01-02T03:04:05.000Z")
        let sent = try #require(try await copy.queue.all().first { $0.kind == .createItem })
        #expect(sent.body["occurred_at"] != nil)
        let write = try #require(
            try await copy.items.update(
                held.id, Edit(properties: [:], baseVersion: held.version, clearOccurredAt: true)))
        #expect(write.body["occurred_at"] == nil)
        let create = try #require(try await copy.queue.all().first { $0.kind == .createItem })
        #expect(create.body["occurred_at"] == nil)
        let cleared = try #require(try await copy.items.get(held.id))
        #expect(cleared.occurredAt == cleared.createdAt && cleared.occurredAt != held.occurredAt)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aRefusedEditLeavesTheTimeOfAnUnsentCreateAlone(kind: CopyKind) async throws {
        let copy = try await kind.open(declaring: [
            ["id": "app.test.needs", "fields": ["name": ["type": "string", "required": true]]]
        ])
        let id = try #require(
            try await copy.items.create(
                Draft(type: "app.test.needs", properties: ["name": "n"], occurredAt: "2026-01-02T03:04:05.000Z")
            ).itemId)
        let held = try #require(try await copy.items.get(id))
        await #expect(
            performing: {
                _ = try await copy.items.update(
                    id,
                    Edit(
                        properties: ["other": "x"], replaceProperties: true, baseVersion: held.version,
                        clearOccurredAt: true))
            }, throws: Self.refused("invalid_properties"))
        let create = try #require(try await copy.queue.all().first { $0.kind == .createItem })
        #expect(create.body["occurred_at"] == "2026-01-02T03:04:05.000Z")
        #expect(try await copy.items.get(id)?.occurredAt == "2026-01-02T03:04:05.000Z")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEditSetsTheOwnTimeAndRefusesToSetAndClearItTogether(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let held = try await Self.note(copy, "timed")
        let write = try #require(
            try await copy.items.update(
                held.id, Edit(properties: [:], baseVersion: held.version, occurredAt: "2026-02-03T04:05:06.000Z")))
        #expect(write.body["occurred_at"] == "2026-02-03T04:05:06.000Z")
        #expect(try await copy.items.get(held.id)?.occurredAt == "2026-02-03T04:05:06.000Z")
        await #expect(
            performing: {
                _ = try await copy.items.update(
                    held.id,
                    Edit(
                        properties: [:], baseVersion: held.version, occurredAt: "2026-02-03T04:05:06.000Z",
                        clearOccurredAt: true))
            }, throws: ItemsOffline.invalid)
        #expect(try await copy.queue.all().filter { $0.kind == .updateItem }.count == 1)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aListNarrowsBySourceAndByTheUpdatedAndOccurredRanges(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let early = try await Self.note(copy, "early") {
            $0.source = "import"
            $0.occurredAt = "2026-01-01T00:00:00.000Z"
        }
        try await Task.sleep(for: .milliseconds(20))
        let late = try await Self.note(copy, "late") { $0.occurredAt = "2026-03-01T00:00:00.000Z" }
        func ids(_ filters: ListFilters) async throws -> [String] { try await copy.items.list(filters).map(\.id) }
        #expect(try await ids(ListFilters(source: "import")) == [early.id])
        #expect(try await ids(ListFilters(updatedAfter: late.updatedAt)) == [late.id])
        #expect(try await ids(ListFilters(updatedBefore: late.updatedAt)) == [early.id])
        #expect(try await ids(ListFilters(occurredAfter: "2026-01-01T00:00:00.000Z")) == [late.id])
        #expect(try await ids(ListFilters(occurredBefore: "2026-03-01T00:00:00.000Z")) == [early.id])
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aListAfterATimeIsOldestChangedFirstAndRefusesAnotherOrder(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let first = try await Self.note(copy, "first")
        try await Task.sleep(for: .milliseconds(20))
        let second = try await Self.note(copy, "second")
        let filters = ListFilters(updatedAfter: first.updatedAt)
        #expect(try await copy.items.list(filters).map(\.id) == [first.id, second.id])
        #expect(
            try await copy.items.list(filters, sort: Sort(direction: .ascending)).map(\.id) == [first.id, second.id])
        await #expect(
            performing: {
                _ = try await copy.items.list(filters, sort: Sort(field: .createdAt, direction: .descending))
            }, throws: Self.refused("validation_error"))
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aPropertySortOrdersNumbersBeforeTextAndLeavesTheMissingLastEitherWay(kind: CopyKind) async throws {
        let copy = try await kind.open()
        func made(_ rank: JSONValue?) async throws -> String {
            var properties: JSONObject = ["body": "b"]
            if let rank { properties["rank"] = rank }
            return try #require(try await copy.items.create(Draft(type: "core.note", properties: properties)).itemId)
        }
        let ten = try await made(10)
        let two = try await made(2)
        let text = try await made("a")
        let none = try await made(nil)
        let up = try await copy.items.list(sort: Sort(field: .property(name: "rank"), direction: .ascending))
        #expect(up.map(\.id) == [two, ten, text, none])
        let down = try await copy.items.list(sort: Sort(field: .property(name: "rank"), direction: .descending))
        #expect(down.map(\.id) == [text, ten, two, none])
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aSortOnAPropertyNameOutsideTheGrammarIsRefusedAndAnUnknownOneLeavesIdOrder(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let ids = [try await Self.note(copy, "a").id, try await Self.note(copy, "b").id].sorted()
        await #expect(
            performing: { _ = try await copy.items.list(sort: Sort(field: .property(name: "Not-Valid"))) },
            throws: Self.refused("validation_error"))
        let unknown = try await copy.items.list(sort: Sort(field: .property(name: "nothing"), direction: .descending))
        #expect(unknown.map(\.id) == ids)
        await copy.close()
    }
}
#endif
