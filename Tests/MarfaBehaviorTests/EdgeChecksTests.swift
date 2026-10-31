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

    /// The refusal, as its code and message with item ids replaced by `<id>`, or `nil` where the call returned.
    ///
    /// The message is the core's own words, so a drift between the fake's and the core's shows as a difference.
    static func code(of call: () async throws -> Void) async -> String? {
        do {
            try await call()
            return nil
        } catch MarfaError.validation(let code, let message) {
            return "\(code): \(normalised(message))"
        } catch MarfaError.notFound(let code, let message) {
            return "\(code): \(normalised(message))"
        } catch {
            return "\(error)"
        }
    }

    /// The message without its kind and code prefix, with item ids replaced.
    static func normalised(_ message: String) -> String {
        message.replacingOccurrences(of: "^[A-Za-z ]+ \\([a-z_]+\\): ", with: "", options: .regularExpression)
            .replacingOccurrences(
                of: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", with: "<id>",
                options: .regularExpression)
    }

    static func noFolder(_ type: String) -> String {
        "edge_constraint_violation: Edge \"in-folder\" does not allow target type \"\(type)\""
    }
    static let nesting =
        "edge_constraint_violation: Edge \"in-collection\" does not take a source its target constraints admit; use \"parent-of\" for hierarchy"
    static let selfLoop = "edge_cycle: an edge from <id> to itself closes a cycle"
    static let cycle = "edge_cycle: Edge \"parent-of\" would close a cycle"

    /// Checks the draft, then creates it, and holds the two to one refusal and the check to queueing nothing.
    static func refusal(
        _ copy: WorkingCopy, from source: String, to target: String, type: String
    ) async throws -> String? {
        let before = try await copy.queue.all().count
        let checked = await code { try await copy.edges.check(from: source, to: target, type: type) }
        #expect(try await copy.queue.all().count == before, "the check queued a write")
        let created = await code { _ = try await copy.edges.create(from: source, to: target, type: type) }
        #expect(
            checked == created, "check said \(String(describing: checked)), create said \(String(describing: created))")
        return checked
    }

    @Test(arguments: CopyKind.allCases)
    func anEndOfATypeTheEdgeTypeDoesNotAdmitIsRefused(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let note = try await Self.item("core.note", in: copy)
        let other = try await Self.item("core.note", in: copy)
        #expect(try await Self.refusal(copy, from: note, to: other, type: "in-folder") == Self.noFolder("core.note"))
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aCollectionInACollectionIsRefusedAsNesting(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let inner = try await Self.item("core.collection", in: copy)
        let outer = try await Self.item("core.collection", in: copy)
        let note = try await Self.item("core.note", in: copy)
        #expect(try await Self.refusal(copy, from: inner, to: outer, type: "in-collection") == Self.nesting)
        #expect(try await Self.refusal(copy, from: note, to: outer, type: "in-collection") == nil)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEndInTheBinIsNotFound(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let source = try await Self.item("core.note", in: copy)
        let binned = try await Self.item("core.note", in: copy)
        _ = try await copy.items.delete(binned)
        #expect(
            try await Self.refusal(copy, from: source, to: binned, type: "references")
                == "item_not_found: Edge target item not found: <id>")
        #expect(
            try await Self.refusal(copy, from: binned, to: source, type: "references")
                == "item_not_found: Edge source item not found: <id>")
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
        #expect(try await Self.refusal(copy, from: c, to: a, type: "parent-of") == Self.cycle)
        #expect(try await Self.refusal(copy, from: a, to: a, type: "parent-of") == Self.selfLoop)
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

    // MARK: The other paths that apply the edge rules

    static func refusal(of call: () async throws -> Void, queued copy: WorkingCopy) async throws -> (String?, Int) {
        let before = try await copy.queue.all().count
        let said = await code(of: call)
        return (said, try await copy.queue.all().count - before)
    }

    @Test(arguments: CopyKind.allCases)
    func anItemCreatedWithEdgesIsHeldToTheEdgeRules(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let outer = try await Self.item("core.collection", in: copy)
        let binned = try await Self.item("core.note", in: copy)
        _ = try await copy.items.delete(binned)
        let title: JSONObject = ["title": .string("made")]
        let nested = try await Self.refusal(
            of: {
                _ = try await copy.items.create(
                    Draft(type: "core.collection", properties: title, edges: ["in-collection": [outer]]))
            },
            queued: copy)
        #expect(nested.0 == Self.nesting)
        #expect(nested.1 == 0, "a refused create queued a write")
        let notAFolder = try await Self.refusal(
            of: {
                _ = try await copy.items.create(
                    Draft(type: "core.note", properties: title, edges: ["in-folder": [outer]]))
            },
            queued: copy)
        #expect(notAFolder.0 == Self.noFolder("core.collection"))
        let inBin = try await Self.refusal(
            of: {
                _ = try await copy.items.create(
                    Draft(type: "core.note", properties: title, edges: ["references": [binned]]))
            },
            queued: copy)
        #expect(inBin.0 == "item_not_found: Edge target item not found: <id>")
        let own = "0190f3a0-0000-7000-8000-0000000000aa"
        let loop = try await Self.refusal(
            of: {
                _ = try await copy.items.create(
                    Draft(type: "core.note", properties: title, id: own, edges: ["parent-of": [own]]))
            },
            queued: copy)
        #expect(loop.0 == Self.selfLoop)
        let fine = try await Self.refusal(
            of: {
                _ = try await copy.items.create(
                    Draft(type: "core.note", properties: title, edges: ["in-collection": [outer]]))
            },
            queued: copy)
        #expect(fine.0 == nil)
        #expect(fine.1 == 1)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aMovedEdgeEndIsHeldToTheEdgeRules(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let a = try await Self.item("core.note", in: copy)
        let b = try await Self.item("core.note", in: copy)
        let c = try await Self.item("core.note", in: copy)
        let d = try await Self.item("core.note", in: copy)
        _ = try await copy.edges.create(from: a, to: b, type: "parent-of")
        _ = try await copy.edges.create(from: b, to: c, type: "parent-of")
        let loose = try #require(try await copy.edges.create(from: d, to: a, type: "parent-of").edgeId)
        let held = try #require(try await copy.edges.get(loose))
        let closing = try await Self.refusal(
            of: { _ = try await copy.edges.update(loose, EdgeEdit(baseVersion: held.version, move: .source(c))) },
            queued: copy)
        #expect(closing.0 == Self.cycle)
        #expect(closing.1 == 0)
        // The built-in edge types that carry constraints are many-to-many, so a move of one is refused for its
        // cardinality before any constraint is read; this holds both copies to that order.
        let outer = try await Self.item("core.collection", in: copy)
        let inner = try await Self.item("core.collection", in: copy)
        let note = try await Self.item("core.note", in: copy)
        let member = try #require(try await copy.edges.create(from: note, to: outer, type: "in-collection").edgeId)
        let memberHeld = try #require(try await copy.edges.get(member))
        let cardinality = try await Self.refusal(
            of: {
                _ = try await copy.edges.update(member, EdgeEdit(baseVersion: memberHeld.version, move: .source(inner)))
            },
            queued: copy)
        #expect(
            cardinality.0
                == "validation_error: in-collection is many-to-many, so the end that stays can hold more than this edge and there is none to replace; create the edge wanted and delete this one"
        )
        let binned = try await Self.item("core.note", in: copy)
        let binnedHeld = try #require(try await copy.edges.create(from: d, to: binned, type: "parent-of").edgeId)
        _ = try await copy.items.delete(binned)
        let spare = try await Self.item("core.note", in: copy)
        let spareHeld = try #require(try await copy.edges.get(binnedHeld))
        let inBin = try await Self.refusal(
            of: {
                _ = try await copy.edges.update(
                    binnedHeld, EdgeEdit(baseVersion: spareHeld.version, move: .source(spare)))
            },
            queued: copy)
        #expect(inBin.0 == "item_not_found: Edge target item not found: <id>")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aRetypeThatBreaksAnEdgeTheItemHoldsIsRefused(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let outer = try await Self.item("core.collection", in: copy)
        let note = try await Self.item("core.note", in: copy)
        _ = try await copy.edges.create(from: note, to: outer, type: "in-collection")
        let noteHeld = try #require(try await copy.items.get(note))
        let outerHeld = try #require(try await copy.items.get(outer))
        let asCollection = try await Self.refusal(
            of: { _ = try await copy.items.update(note, Edit(baseVersion: noteHeld.version, type: "core.collection")) },
            queued: copy)
        #expect(asCollection.0 == Self.nesting)
        #expect(asCollection.1 == 0)
        let asNote = try await Self.refusal(
            of: { _ = try await copy.items.update(outer, Edit(baseVersion: outerHeld.version, type: "core.note")) },
            queued: copy)
        #expect(
            asNote.0 == "edge_constraint_violation: Edge \"in-collection\" does not allow target type \"core.note\"")
        #expect(asNote.1 == 0)
        let held = try #require(try await copy.items.get(outer))
        #expect(held.type == "core.collection")
        let harmless = try await Self.refusal(
            of: { _ = try await copy.items.update(note, Edit(baseVersion: noteHeld.version, type: "core.task")) },
            queued: copy)
        #expect(harmless.0 != nil || harmless.1 == 1)
        await copy.close()
    }
}
#endif
