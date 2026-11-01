#if DEBUG
import Marfa
import MarfaTesting
import Testing

/// The calls that need the Rust core's rules: the fake answers them only as a test scripts.
@Suite(.timeLimit(.minutes(1)))
struct FakeScriptedAnswersBehavior {
    static let note = Item(
        id: "01a1500d-78bd-73f0-8c55-2a4160c5ff20", type: "note", properties: ["title": "Sweep", "body": "Floors"],
        state: .active, tier: .library, version: 1, schemaVersion: 1, source: "app", sourceId: nil,
        occurredAt: "2026-09-26T00:00:00.000Z", createdAt: "2026-09-26T00:00:00.000Z",
        updatedAt: "2026-09-26T00:00:00.000Z", tags: [], title: "Sweep")

    @Test func displaysAreUnsupportedUntilScripted() async throws {
        let fake = WorkingCopy.fake(items: [Self.note])
        await #expect(throws: FakeCopyError.unsupported(call: "items.displays")) {
            try await fake.copy.items.displays(of: [Self.note])
        }
    }

    @Test func aScriptedDisplayArrivesThroughBothPublicCalls() async throws {
        let fake = WorkingCopy.fake(items: [Self.note])
        fake.displays = { input in
            ItemDisplay(name: input.properties["title"]?.string, preview: input.properties["body"]?.string)
        }
        let shown = try await fake.copy.items.displays(of: [Self.note, Self.note])
        #expect(shown == Array(repeating: ItemDisplay(name: "Sweep", preview: "Floors"), count: 2))
        let drafted = try await fake.copy.items.displays(for: [ItemDisplayInput(type: "note", properties: [:])])
        #expect(drafted == [ItemDisplay(name: nil, preview: nil)])
    }

    @Test func aDisplayGivenAtCreationIsServedAndCanBeRemoved() async throws {
        let fake = WorkingCopy.fake(displays: { _ in ItemDisplay(name: "Fixed", preview: nil) })
        #expect(try await fake.copy.items.displays(of: [Self.note]) == [ItemDisplay(name: "Fixed", preview: nil)])
        fake.displays = nil
        await #expect(throws: FakeCopyError.unsupported(call: "items.displays")) {
            try await fake.copy.items.displays(of: [Self.note])
        }
    }

    @Test func linkCandidatesAreUnsupportedUntilScripted() async throws {
        let fake = WorkingCopy.fake()
        await #expect(throws: FakeCopyError.unsupported(call: "links.candidates")) {
            try await fake.copy.items.linkCandidates(of: ["Sweep"])
        }
    }

    @Test func scriptedLinkCandidatesAnswerEachTargetInOrderWithTheItemAsked() async throws {
        let fake = WorkingCopy.fake()
        fake.linkCandidates = { target, item in
            target == "Sweep"
                ? LinkCandidates(target: target, state: .bound, item: item, candidates: ["a"])
                : LinkCandidates(target: target, state: .unresolved, item: nil, candidates: [])
        }
        let answers = try await fake.copy.items.linkCandidates(of: ["Sweep", "Nothing"], in: "a")
        #expect(
            answers == [
                LinkCandidates(target: "Sweep", state: .bound, item: "a", candidates: ["a"]),
                LinkCandidates(target: "Nothing", state: .unresolved, item: nil, candidates: []),
            ])
    }
}
#endif
