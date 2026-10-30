#if DEBUG
import Foundation
import Marfa
import Testing

/// A type's status words and groups, and the fixed values of an event's status.
///
/// Both copies are held to the same answers.
@Suite(.timeLimit(.minutes(1)))
struct StatusOffline {
    static let taskWords = ["not_started", "in_progress", "completed", "canceled"]
    static let undeclared =
        "status: Must be a status word the type declares: not_started, in_progress, completed, canceled"

    static func refused(_ message: String) -> (any Error) -> Bool {
        { error in
            if case .validation("invalid_properties", let given)? = error as? MarfaError {
                given.hasSuffix(message)
            } else {
                false
            }
        }
    }

    /// The item a create makes, as the copy shows it.
    static func made(_ draft: Draft, in copy: WorkingCopy) async throws -> Item {
        let id = try #require(try await copy.items.create(draft).itemId)
        return try #require(try await copy.items.get(id))
    }

    @Test(arguments: CopyKind.allCases)
    func aTypeReadGivesEachStatusWordWithItsGroup(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let task = try await copy.catalog.itemType("core.task")
        #expect(task.statusField == "status")
        #expect(task.statusWords.map(\.value) == Self.taskWords)
        #expect(task.statusWords.map(\.group) == StatusGroup.allCases)
        #expect(task.statusGroup(of: "completed") == .completed)
        #expect(task.statusGroup(of: "todo") == nil, "the witness: a word the type does not declare has no group")
        let note = try await copy.catalog.itemType("core.note")
        #expect(note.statusField == nil && note.statusWords.isEmpty)
        #expect(note.statusGroup(of: "completed") == nil)
        await copy.close()
    }

    @Test func theGroupsAreTheWordsTheAPIUses() {
        #expect(StatusGroup.allCases.map(\.rawValue) == ["not_started", "in_progress", "completed", "canceled"])
        #expect(StatusGroup(rawValue: "inProgress") == nil)
    }

    @Test(arguments: CopyKind.allCases)
    func anItemsGroupComesFromItsOwnTypesWords(kind: CopyKind) async throws {
        let copy = try await kind.open()
        func made(_ draft: Draft) async throws -> Item { try await Self.made(draft, in: copy) }
        let started = try await made(Draft(type: "core.task", properties: ["title": "a", "status": "in_progress"]))
        let bare = try await made(Draft(type: "core.task", properties: ["title": "b"]))
        let cleared = try await made(Draft(type: "core.task", properties: ["title": "c", "status": .null]))
        let note = try await made(Draft(type: "core.note", properties: ["body": "n", "status": "completed"]))

        #expect(try await copy.catalog.statusGroup(of: started) == .inProgress)
        #expect(try await copy.catalog.statusGroup(of: bare) == nil, "an item with no status is in no group")
        #expect(try await copy.catalog.statusGroup(of: cleared) == nil)
        #expect(
            try await copy.catalog.statusGroup(of: note) == nil, "a type with no status field has no group to read")
        #expect(
            try await copy.catalog.statusGroups(of: [note, started, bare, started]) == [
                nil, .inProgress, nil, .inProgress,
            ])
        #expect(try await copy.catalog.statusGroups(of: []).isEmpty)

        let task = try await copy.catalog.itemType("core.task")
        #expect(task.statusGroup(of: started) == .inProgress)
        #expect(task.statusGroup(of: note) == nil, "an item of another type is read with its own type's words")
        var stale = started
        stale.properties["status"] = "pending"
        #expect(try await copy.catalog.statusGroup(of: stale) == nil, "a word the type no longer declares")
        stale.properties["status"] = 3
        #expect(try await copy.catalog.statusGroup(of: stale) == nil)

        var unknown = started
        unknown.type = "app.nope.type"
        await #expect {
            _ = try await copy.catalog.statusGroup(of: unknown)
        } throws: { error in
            if case .notFound("type_not_found", _)? = error as? MarfaError { true } else { false }
        }
        #expect(
            try await copy.catalog.statusGroups(of: [started, unknown, note, unknown, started]) == [
                .inProgress, nil, nil, nil, .inProgress,
            ], "a type the catalog does not hold gives that item nothing and fails no other")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aTaskTakesTheWordsItsTypeDeclaresAndNoOther(kind: CopyKind) async throws {
        let copy = try await kind.open()
        for word in Self.taskWords {
            _ = try await copy.items.create(
                Draft(type: "core.task", properties: ["title": "t", "status": .string(word)]))
        }
        _ = try await copy.items.create(Draft(type: "core.task", properties: ["title": "t", "status": .null]))
        _ = try await copy.items.create(Draft(type: "core.task", properties: ["title": "t"]))
        let queued = try await copy.queue.all().count
        #expect(queued == 6)

        await #expect(
            performing: {
                _ = try await copy.items.create(Draft(type: "core.task", properties: ["title": "t", "status": "todo"]))
            }, throws: Self.refused(Self.undeclared))
        await #expect {
            _ = try await copy.items.create(Draft(type: "core.task", properties: ["title": "t", "status": 3]))
        } throws: { error in
            if case .validation("invalid_properties", let message)? = error as? MarfaError {
                message.hasSuffix("status: Expected string")
            } else {
                false
            }
        }
        #expect(try await copy.queue.all().count == queued, "a refused create queues nothing")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anUpdateIsRefusedForAnUndeclaredWordItChangesTheItemTo(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let id = try #require(
            try await copy.items.create(Draft(type: "core.task", properties: ["title": "t", "status": "in_progress"]))
                .itemId)
        await #expect(
            performing: {
                _ = try await copy.items.update(id, Edit(properties: ["status": "waiting"], baseVersion: 0))
            }, throws: Self.refused(Self.undeclared))
        await #expect(
            performing: {
                _ = try await copy.items.update(
                    id, Edit(properties: ["title": "t2", "status": "todo"], replaceProperties: true, baseVersion: 0))
            }, throws: Self.refused(Self.undeclared))
        #expect(try await copy.items.get(id)?.properties["status"] == "in_progress")

        _ = try await copy.items.update(id, Edit(properties: ["status": "completed"], baseVersion: 0))
        #expect(try await copy.items.get(id)?.properties["status"] == "completed")
        _ = try await copy.items.update(id, Edit(properties: ["status": .null], baseVersion: 0))
        #expect(try await copy.items.get(id)?.properties["status"] == "completed", "a null keeps the held word")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aMoveIsRefusedWhereTheTargetDoesNotDeclareTheWordTheItemHolds(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let held = try #require(
            try await copy.items.create(Draft(type: "core.note", properties: ["title": "n", "status": "pending"]))
                .itemId)
        await #expect(
            performing: {
                _ = try await copy.items.update(held, Edit(baseVersion: 0, type: "core.task"))
            }, throws: Self.refused(Self.undeclared))
        #expect(try await copy.items.get(held)?.type == "core.note", "a refused move keeps the item where it was")

        let declared = try #require(
            try await copy.items.create(Draft(type: "core.note", properties: ["title": "n", "status": "completed"]))
                .itemId)
        _ = try await copy.items.update(declared, Edit(baseVersion: 0, type: "core.task"))
        #expect(try await copy.items.get(declared)?.type == "core.task")

        let plain = try #require(
            try await copy.items.create(Draft(type: "core.note", properties: ["title": "n"])).itemId)
        _ = try await copy.items.update(plain, Edit(baseVersion: 0, type: "core.task"))
        #expect(try await copy.items.get(plain)?.type == "core.task")
        await copy.close()
    }

    static func statuses(of items: [Item], in copy: WorkingCopy) async throws -> [EventStatus?] {
        var statuses: [EventStatus?] = []
        for item in items { statuses.append(try await copy.catalog.eventStatus(of: item)) }
        return statuses
    }

    @Test(arguments: CopyKind.allCases)
    func anEventsStatusIsOneOfThreeValuesTheSDKTypes(kind: CopyKind) async throws {
        let copy = try await kind.open()
        var events: [Item] = []
        for status in EventStatus.allCases {
            let draft = Draft(type: "core.event", properties: ["title": "Standup", "status": .string(status.rawValue)])
            events.append(try await Self.made(draft, in: copy))
        }
        #expect(try await Self.statuses(of: events, in: copy) == [.tentative, .confirmed, .canceled])
        let bare = try await Self.made(Draft(type: "core.event", properties: ["title": "x"]), in: copy)
        #expect(try await copy.catalog.eventStatus(of: bare) == nil, "an event with no status has none to read")
        let note = try await Self.made(
            Draft(type: "core.note", properties: ["body": "b", "status": "confirmed"]), in: copy)
        #expect(try await copy.catalog.eventStatus(of: note) == nil, "an item that is not an event has no event status")
        var unknown = events[0]
        unknown.properties["status"] = "postponed"
        #expect(try await copy.catalog.eventStatus(of: unknown) == nil, "a value this SDK does not know")
        unknown.properties["status"] = 3
        #expect(try await copy.catalog.eventStatus(of: unknown) == nil, "a value that is not a string")
        unknown.type = "app.nope.type"
        await #expect {
            _ = try await copy.catalog.eventStatus(of: unknown)
        } throws: { error in
            if case .notFound("type_not_found", _)? = error as? MarfaError { true } else { false }
        }

        await #expect {
            _ = try await copy.items.create(
                Draft(type: "core.event", properties: ["title": "x", "status": "postponed"]))
        } throws: { error in
            if case .validation("invalid_properties", let message)? = error as? MarfaError {
                message.hasSuffix("status: Must be one of \"tentative\", \"confirmed\", \"canceled\"")
            } else {
                false
            }
        }
        await #expect {
            _ = try await copy.items.update(
                events[0].id, Edit(properties: ["status": "maybe"], baseVersion: 0))
        } throws: { error in
            if case .validation("invalid_properties", _)? = error as? MarfaError { true } else { false }
        }
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aSubtypeOfEventHoldsTheSameThreeValuesAndIsReadTheSame(kind: CopyKind) async throws {
        let copy = try await kind.open()
        try await copy.declareTypes([
            ["id": "app.test.meeting", "parent": "core.event"],
            ["id": "app.test.standup", "parent": "app.test.meeting"],
            ["id": "app.test.errand", "parent": "core.task"],
        ])
        var meetings: [Item] = []
        for type in ["app.test.meeting", "app.test.standup"] {
            for status in EventStatus.allCases {
                let draft = Draft(type: type, properties: ["title": "Sync", "status": .string(status.rawValue)])
                meetings.append(try await Self.made(draft, in: copy))
            }
        }
        #expect(
            try await Self.statuses(of: meetings, in: copy)
                == [.tentative, .confirmed, .canceled, .tentative, .confirmed, .canceled],
            "a subtype, and a subtype of it, are events")
        let errand = try await Self.made(
            Draft(type: "app.test.errand", properties: ["title": "Post", "status": "completed"]), in: copy)
        #expect(try await copy.catalog.eventStatus(of: errand) == nil, "a subtype of another type is not an event")

        await #expect {
            _ = try await copy.items.create(
                Draft(type: "app.test.meeting", properties: ["title": "x", "status": "postponed"]))
        } throws: { error in
            if case .validation("invalid_properties", let message)? = error as? MarfaError {
                message.hasSuffix("status: Must be one of \"tentative\", \"confirmed\", \"canceled\"")
            } else {
                false
            }
        }
        await copy.close()
    }
}
#endif
