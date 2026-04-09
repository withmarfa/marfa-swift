import Testing
import Foundation
@testable import MymeSDK

@Suite("Conflict Resolution")
struct ConflictTests {

    @Test("Auto-merge keeps client changes for non-conflicting fields")
    func autoMergeNonConflicting() {
        let conflict = ConflictData(
            current: ConflictSnapshot(version: 2, properties: [
                "title": .string("Server Title"),
                "body": .string("Server Body"),
            ]),
            ancestor: ConflictSnapshot(version: 1, properties: [
                "title": .string("Original Title"),
                "body": .string("Original Body"),
            ]),
            conflictingFields: ["title"],
            clientPatch: [
                "title": .string("Client Title"),
                "body": .string("Client Body"),
            ]
        )

        let merged = autoMerge(conflict: conflict)

        // Server wins on conflicting field
        #expect(merged["title"] == .string("Server Title"))
        // Client wins on non-conflicting field
        #expect(merged["body"] == .string("Client Body"))
    }

    @Test("Auto-merge with no conflicts applies all client changes")
    func autoMergeNoConflicts() {
        let conflict = ConflictData(
            current: ConflictSnapshot(version: 2, properties: [
                "title": .string("Server Title"),
            ]),
            ancestor: ConflictSnapshot(version: 1, properties: [:]),
            conflictingFields: [],
            clientPatch: [
                "title": .string("Client Title"),
                "body": .string("New Body"),
            ]
        )

        let merged = autoMerge(conflict: conflict)

        #expect(merged["title"] == .string("Client Title"))
        #expect(merged["body"] == .string("New Body"))
    }

    @Test("Auto-merge with all fields conflicting keeps server values")
    func autoMergeAllConflicting() {
        let conflict = ConflictData(
            current: ConflictSnapshot(version: 2, properties: [
                "title": .string("Server Title"),
                "body": .string("Server Body"),
            ]),
            ancestor: ConflictSnapshot(version: 1, properties: [:]),
            conflictingFields: ["title", "body"],
            clientPatch: [
                "title": .string("Client Title"),
                "body": .string("Client Body"),
            ]
        )

        let merged = autoMerge(conflict: conflict)

        #expect(merged["title"] == .string("Server Title"))
        #expect(merged["body"] == .string("Server Body"))
    }
}
