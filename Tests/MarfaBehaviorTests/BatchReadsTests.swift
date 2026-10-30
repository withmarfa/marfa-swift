#if DEBUG
import Foundation
import Marfa
import Testing

/// Reads of many items or edges by ID, on a copy that never reached a server.
@Suite(.timeLimit(.minutes(1)))
struct BatchReads {
    @Test(arguments: CopyKind.allCases)
    func itemsComeOnceEachInTheOrderFirstNamedLeavingOutWhatTheCopyDoesNotHold(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let a = try await ItemsOffline.note("a", in: copy, tags: ["x"])
        let b = try await ItemsOffline.note("b", in: copy)
        let archived = try await ItemsOffline.note("archived", in: copy)
        _ = try await copy.items.transition(archived, to: .archived)

        let read = try await copy.items.get([b, "absent", a, b, archived])
        #expect(read.map(\.id) == [b, a, archived])
        #expect(read.completeness == .complete)
        for item in read {
            #expect(try await copy.items.get(item.id) == item)
        }
        #expect(read[2].state == .archived)
        #expect(try await copy.items.get([]).isEmpty)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anItemInTheBinComesOnlyWhenAskedFor(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let kept = try await ItemsOffline.note("kept", in: copy)
        let binned = try await ItemsOffline.note("binned", in: copy)
        _ = try await copy.items.delete(binned)

        #expect(try await copy.items.get([binned, kept]).map(\.id) == [kept])
        let withBin = try await copy.items.get([binned, kept], includingBin: true)
        #expect(withBin.map(\.id) == [binned, kept])
        #expect(withBin[0].state == .trashed)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func edgesComeOnceEachInTheOrderFirstNamedLeavingOutWhatTheCopyDoesNotHold(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let a = try await ItemsOffline.note("a", in: copy)
        let b = try await ItemsOffline.note("b", in: copy)
        let c = try await ItemsOffline.note("c", in: copy)
        let ab = try #require(try await copy.edges.create(from: a, to: b, type: "about").edgeId)
        let ac = try #require(
            try await copy.edges.create(from: a, to: c, type: "about", properties: ["why": "kept"]).edgeId)
        let removed = try #require(try await copy.edges.create(from: b, to: c, type: "about").edgeId)
        _ = try await copy.edges.delete(removed)

        let held = try await copy.edges.from(a)
        let one = try #require(try await copy.edges.get(ac))
        #expect(one == held.first { $0.id == ac })
        #expect(one.properties == ["why": "kept"])
        #expect(try await copy.edges.get("absent") == nil)
        #expect(try await copy.edges.get(removed) == nil)

        let many = try await copy.edges.get([ac, "absent", removed, ab, ac])
        #expect(many.map(\.id) == [ac, ab])
        #expect(many.first == one)
        #expect(try await copy.edges.get([String]()).isEmpty)
        await copy.close()
    }
}
#endif
