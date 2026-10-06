import Foundation
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct ConflictedCopiesOffline {
    private func note(_ title: String, tags: [String] = [], in copy: WorkingCopy) async throws -> String {
        try #require(
            try await copy.items.create(
                Draft(type: "core.note", properties: ["title": .string(title), "body": "text"], tags: tags)
            ).itemId)
    }

    private func conflictedCopy(of original: String, in copy: WorkingCopy) async throws -> String {
        let made = try await note("copy of \(original)", tags: ["conflicted-copy"], in: copy)
        _ = try await copy.edges.create(from: made, to: original, type: "derived-from")
        return made
    }

    @Test func aConflictedCopyAndItsOriginalLeadToEachOther() async throws {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        let original = try await note("original", in: copy)
        let first = try await conflictedCopy(of: original, in: copy)
        let second = try await conflictedCopy(of: original, in: copy)
        let other = try await note("other", in: copy)
        _ = try await conflictedCopy(of: other, in: copy)

        #expect(try await copy.items.original(ofConflictedCopy: first) == original)
        let copies = try await copy.items.conflictedCopies(of: original)
        #expect(copies.map(\.id) == [first, second])
        #expect(copies.allSatisfy { $0.tags.contains("conflicted-copy") })
        await copy.close()

        let reopened = try await WorkingCopy.open(store: store)
        #expect(try await reopened.items.original(ofConflictedCopy: second) == original)
        #expect(try await reopened.items.conflictedCopies(of: original).map(\.id) == [first, second])
        await reopened.close()
    }

    @Test func anItemThatIsNotAConflictedCopyHasNoOriginalAndNoCopies() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let original = try await note("original", in: copy)
        let derived = try await note("derived but not a copy", in: copy)
        _ = try await copy.edges.create(from: derived, to: original, type: "derived-from")

        #expect(try await copy.items.original(ofConflictedCopy: original) == nil)
        #expect(try await copy.items.original(ofConflictedCopy: derived) == nil)
        #expect(try await copy.items.original(ofConflictedCopy: "no-such-item") == nil)
        #expect(try await copy.items.conflictedCopies(of: original).isEmpty)
        #expect(try await copy.items.conflictedCopies(of: "no-such-item").isEmpty)
        await copy.close()
    }

    @Test func aConflictedCopyInTheBinIsNotAnswered() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let original = try await note("original", in: copy)
        let kept = try await conflictedCopy(of: original, in: copy)
        let binned = try await conflictedCopy(of: original, in: copy)
        _ = try await copy.items.delete(binned)

        #expect(try await copy.items.original(ofConflictedCopy: binned) == nil)
        #expect(try await copy.items.conflictedCopies(of: original).map(\.id) == [kept])
        await copy.close()
    }

    @Test func theOriginalNeedNotBeHeld() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let missing = UUID().uuidString.lowercased()
        let held = try await conflictedCopy(of: missing, in: copy)

        #expect(try await copy.items.original(ofConflictedCopy: held) == missing)
        #expect(try await copy.items.conflictedCopies(of: missing).map(\.id) == [held])
        await copy.close()
    }
}
