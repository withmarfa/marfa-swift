import Foundation
import Testing

@testable import Marfa

/// The status words a subtype adds, held by the real copy only: the fake copy leaves declaring a status field's words
/// unsupported.
@Suite(.timeLimit(.minutes(1)))
struct StatusWords {
    static let subtype: JSONObject = [
        "id": "app.test.chore", "parent": "core.task",
        "fields": [
            "status": [
                "type": "status",
                "status_values": [["value": "blocked", "group": "in_progress"]],
            ]
        ],
    ]

    @Test func aSubtypeHoldsItsParentsWordsAndTheOnesItAdds() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        try await copy.declareTypes([Self.subtype])
        let chore = try await copy.catalog.itemType("app.test.chore")
        #expect(
            chore.statusWords.map(\.value) == ["not_started", "in_progress", "completed", "canceled", "blocked"],
            "the parent's words come first and the subtype's own last")
        #expect(chore.statusGroup(of: "blocked") == .inProgress)
        #expect(chore.statusField == "status")
        let task = try await copy.catalog.itemType("core.task")
        #expect(task.statusWords.count == 4, "a subtype's words do not reach its parent")
        #expect(task.statusGroup(of: "blocked") == nil)
        await copy.close()
    }

    @Test func aSubtypesItemIsReadWithTheSubtypesWordsAndNotItsParents() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        try await copy.declareTypes([Self.subtype])
        let blocked = try #require(
            try await copy.items.create(
                Draft(type: "app.test.chore", properties: ["title": "Fix", "status": "blocked"])
            ).itemId)
        let item = try #require(try await copy.items.get(blocked))
        #expect(try await copy.catalog.statusGroup(of: item) == .inProgress)
        let task = try await copy.catalog.itemType("core.task")
        #expect(task.statusGroup(of: item) == nil, "the parent's words, read for an item of the subtype, give nothing")
        await #expect {
            _ = try await copy.items.create(
                Draft(type: "core.task", properties: ["title": "Fix", "status": "blocked"]))
        } throws: { error in
            if case .validation("invalid_properties", let message)? = error as? MarfaError {
                message.hasSuffix(
                    "status: Must be a status word the type declares: not_started, in_progress, completed, canceled")
            } else {
                false
            }
        }
        await copy.close()
    }
}
