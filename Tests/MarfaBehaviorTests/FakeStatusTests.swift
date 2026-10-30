#if DEBUG
import Foundation
import Marfa
import MarfaTesting
import Testing

/// What only the fake does with a status field: what it is given, and what it will not judge.
@Suite(.timeLimit(.minutes(1)))
struct FakeStatusBehavior {
    static func words(_ words: [(String, String)]) -> JSONValue {
        .array(words.map { ["value": .string($0.0), "group": .string($0.1)] })
    }

    static func choreType(words: [(String, String)] = [("open", "not_started"), ("done", "completed")]) -> ItemType {
        ItemType(
            id: "app.test.chore",
            fields: [
                TypeField(
                    name: "title", type: "string", required: true, declaredBy: "app.test.chore",
                    definition: ["type": "string", "required": true]),
                TypeField(
                    name: "stage", type: "status", declaredBy: "app.test.chore",
                    definition: ["type": "status", "status_values": Self.words(words)]),
            ])
    }

    static func chore(stage: JSONValue) -> Item {
        Item(
            id: "01a1500d-78bd-73f0-8c55-2a4160c5ff10", type: "app.test.chore",
            properties: ["title": "Sweep", "stage": stage], state: .active, tier: .library, version: 1,
            schemaVersion: 1, source: "app", sourceId: nil, occurredAt: "2026-09-26T00:00:00.000Z",
            createdAt: "2026-09-26T00:00:00.000Z", updatedAt: "2026-09-26T00:00:00.000Z", tags: [], title: "Sweep")
    }

    @Test func aTypeTheAppBuildsGivesItsWordsAndGroupsToTheCatalog() async throws {
        let fake = WorkingCopy.fake(itemTypes: [Self.choreType()])
        let type = try await fake.copy.catalog.itemType("app.test.chore")
        #expect(type.statusField == "stage")
        #expect(
            type.statusWords == [
                StatusWord(value: "open", group: .notStarted), StatusWord(value: "done", group: .completed),
            ])
        #expect(try await fake.copy.catalog.statusGroup(of: Self.chore(stage: "done")) == .completed)
        await fake.copy.close()
    }

    @Test func aStoredWordTheTypeNoLongerDeclaresStandsThroughAnEditThatLeavesItAlone() async throws {
        let held = Self.chore(stage: "pending")
        let copy = WorkingCopy.fake(items: [held], itemTypes: [Self.choreType()]).copy
        _ = try await copy.items.update(held.id, Edit(properties: ["title": "Mop"], baseVersion: 1))
        #expect(try await copy.items.get(held.id)?.properties["stage"] == "pending")
        _ = try await copy.items.update(
            held.id, Edit(properties: ["title": "Mop", "stage": "pending"], replaceProperties: true, baseVersion: 1))
        #expect(try await copy.items.get(held.id)?.properties["stage"] == "pending")
        await #expect {
            _ = try await copy.items.update(held.id, Edit(properties: ["stage": "waiting"], baseVersion: 1))
        } throws: { error in
            if case .validation("invalid_properties", let message)? = error as? MarfaError {
                message.hasSuffix("stage: Must be a status word the type declares: open, done")
            } else {
                false
            }
        }
        _ = try await copy.items.update(held.id, Edit(properties: ["stage": "done"], baseVersion: 1))
        #expect(try await copy.items.get(held.id)?.properties["stage"] == "done")
        await copy.close()
    }

    @Test(
        arguments: [
            ["not_words": 1], ["status_values": []], ["status_values": [["value": "open"]]],
            ["status_values": [["value": "open", "group": "not_started"], ["value": 3, "group": "completed"]]],
        ] as [JSONObject])
    func aStatusFieldTheFakeCannotReadIsUnsupportedWhateverTheWord(listing: JSONObject) async throws {
        var definition: JSONObject = ["type": "status"]
        for (key, value) in listing { definition[key] = value }
        let type = ItemType(
            id: "app.test.chore",
            fields: [TypeField(name: "stage", type: "status", declaredBy: "app.test.chore", definition: definition)])
        let copy = WorkingCopy.fake(itemTypes: [type]).copy
        for stage: JSONValue in ["open", "other"] {
            await #expect {
                _ = try await copy.items.create(Draft(type: "app.test.chore", properties: ["stage": stage]))
            } throws: { error in
                guard case .unsupported(let call)? = error as? FakeCopyError else { return false }
                return call.contains("status field") || call.contains("constrained")
            }
        }
        await copy.close()
    }

    @Test func aDeclaredTypeWithAStatusFieldOrStatusWordsIsUnsupportedWhereARealCopyJudgesIt() async throws {
        let copy = WorkingCopy.fake().copy
        let listed = Self.words([("open", "not_started")])
        let declarations: [JSONObject] = [
            ["id": "app.test.chore", "fields": ["stage": ["type": "status", "status_values": listed]]],
            ["id": "app.test.chore", "fields": ["stage": ["type": "string", "status_values": listed]]],
            ["id": "app.test.chore", "fields": ["stages": ["type": "array", "items_type": "status"]]],
        ]
        for declaration in declarations {
            await #expect {
                try await copy.declareTypes([declaration])
            } throws: { error in
                guard case .unsupported(let call)? = error as? FakeCopyError else { return false }
                return call.contains("status")
            }
        }
        #expect(try await copy.declaredTypes().isEmpty)
        await copy.close()
    }

    @Test func aFilterNamingAStatusGroupIsUnsupportedOnAList() async throws {
        let fake = WorkingCopy.fake(itemTypes: [Self.choreType()])
        await #expect {
            _ = try await fake.copy.items.list(ListFilters(filter: "status_group neq \"completed\""))
        } throws: { error in
            (error as? FakeCopyError) == .unsupported(call: "items.list(filter:)")
        }
        await fake.copy.close()
    }
}
#endif
