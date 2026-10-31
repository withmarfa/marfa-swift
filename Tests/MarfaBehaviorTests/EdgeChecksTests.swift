#if DEBUG
import Foundation
import Marfa
import Testing

/// What a copy that never reached a server refuses about an edge, from the catalog and rows it holds.
@Suite(.timeLimit(.minutes(1)))
struct EdgeChecksOffline {
    static func item(_ type: String, in copy: WorkingCopy) async throws -> String {
        try #require(
            try await copy.items.create(Draft(type: type, properties: ["title": .string("\(type) \(UUID())")]))
                .itemId)
    }

    /// The code of the refusal, or `nil` where the call returned.
    static func code(of call: () async throws -> Void) async -> String? {
        do {
            try await call()
            return nil
        } catch MarfaError.validation(let code, _) {
            return code
        } catch MarfaError.notFound(let code, _) {
            return code
        } catch {
            return "\(error)"
        }
    }

    /// Checks the draft, then creates it, and holds the two to one refusal and the check to queueing nothing.
    static func refusal(
        _ copy: WorkingCopy, from source: String, to target: String, type: String
    ) async throws -> String? {
        let before = try await copy.queue.all().count
        let checked = await code { try await copy.edges.check(from: source, to: target, type: type) }
        #expect(try await copy.queue.all().count == before, "the check queued a write")
        let created = await code { _ = try await copy.edges.create(from: source, to: target, type: type) }
        #expect(checked == created, "check said \(String(describing: checked)), create said \(String(describing: created))")
        return checked
    }

    @Test(arguments: CopyKind.allCases)
    func anEndOfATypeTheEdgeTypeDoesNotAdmitIsRefused(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let note = try await Self.item("core.note", in: copy)
        let other = try await Self.item("core.note", in: copy)
        #expect(try await Self.refusal(copy, from: note, to: other, type: "in-folder") == "edge_constraint_violation")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aCollectionInACollectionIsRefusedAsNesting(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let inner = try await Self.item("core.collection", in: copy)
        let outer = try await Self.item("core.collection", in: copy)
        let note = try await Self.item("core.note", in: copy)
        #expect(try await Self.refusal(copy, from: inner, to: outer, type: "in-collection") == "edge_constraint_violation")
        #expect(try await Self.refusal(copy, from: note, to: outer, type: "in-collection") == nil)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEndInTheBinIsNotFound(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let source = try await Self.item("core.note", in: copy)
        let binned = try await Self.item("core.note", in: copy)
        _ = try await copy.items.delete(binned)
        #expect(try await Self.refusal(copy, from: source, to: binned, type: "references") == "item_not_found")
        #expect(try await Self.refusal(copy, from: binned, to: source, type: "references") == "item_not_found")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEdgeThatClosesACycleThroughHeldEdgesIsRefused(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let a = try await Self.item("core.note", in: copy)
        let b = try await Self.item("core.note", in: copy)
        let c = try await Self.item("core.note", in: copy)
        _ = try await copy.edges.create(from: a, to: b, type: "parent-of")
        _ = try await copy.edges.create(from: b, to: c, type: "parent-of")
        #expect(try await Self.refusal(copy, from: c, to: a, type: "parent-of") == "edge_cycle")
        #expect(try await Self.refusal(copy, from: a, to: a, type: "parent-of") == "edge_cycle")
        #expect(try await Self.refusal(copy, from: c, to: a, type: "references") == nil, "a type that may cycle")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aDraftTheCopyTakesReturnsAndQueuesNothing(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let a = try await Self.item("core.note", in: copy)
        let b = try await Self.item("core.note", in: copy)
        let before = try await copy.queue.all().count
        try await copy.edges.check(from: a, to: b, type: "parent-of")
        #expect(try await copy.queue.all().count == before)
        #expect(try await copy.edges.from(a).isEmpty)
        let made = try await copy.edges.create(from: a, to: b, type: "parent-of")
        #expect(made.kind == .createEdge)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func theCatalogSaysWhichEdgeTypesAreAcyclicAndFlat(kind: CopyKind) async throws {
        let copy = try await kind.open()
        #expect(try await copy.catalog.edgeType("parent-of").acyclic)
        #expect(try await copy.catalog.edgeType("in-collection").flat)
        #expect(try await copy.catalog.edgeType("references").acyclic == false)
        await copy.close()
    }
}
#endif
