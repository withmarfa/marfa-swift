#if DEBUG
import Foundation
import Marfa
import Testing

private func refused(with code: String) -> (any Error) -> Bool {
    { error in
        if case .validation(let given, _, _)? = error as? MarfaError { given == code } else { false }
    }
}

/// A copy that never reached a server, holding the built-in catalog.
@Suite(.timeLimit(.minutes(1)))
struct EdgeMoveOffline {
    struct Tree {
        let copy: WorkingCopy
        let parent: String
        let other: String
        let child: String
        let edge: String
    }

    static func note(_ title: String, in copy: WorkingCopy) async throws -> String {
        try #require(
            try await copy.items.create(Draft(type: "core.note", properties: ["title": .string(title), "body": "b"]))
                .itemId)
    }

    /// `parent` holds `child` through a `parent-of` edge, and `other` holds nothing.
    static func tree(_ kind: CopyKind) async throws -> Tree {
        let copy = try await kind.open()
        let parent = try await note("parent", in: copy)
        let other = try await note("other", in: copy)
        let child = try await note("child", in: copy)
        let edge = try #require(try await copy.edges.create(from: parent, to: child, type: "parent-of").edgeId)
        return Tree(copy: copy, parent: parent, other: other, child: child, edge: edge)
    }

    @Test(arguments: CopyKind.allCases)
    func aMovedSourceShowsAtOnceAtItsNewEndAndQueuesOneWrite(kind: CopyKind) async throws {
        let tree = try await Self.tree(kind)
        let held = try #require(try await tree.copy.edges.to(tree.child).first)
        let before = try await tree.copy.queue.all().count

        let write = try #require(
            try await tree.copy.edges.update(
                tree.edge, EdgeEdit(baseVersion: held.version, move: .source(tree.other))))

        #expect(write.kind == .updateEdge)
        #expect(write.edgeId == tree.edge)
        #expect(write.baseVersion == held.version)
        #expect(write.body["source_id"] == .string(tree.other))
        #expect(write.body["target_id"] == nil, "the end that stays was sent: \(write.body)")
        #expect(try await tree.copy.queue.all().count == before + 1)
        #expect(try await tree.copy.edges.from(tree.parent).isEmpty)
        #expect(try await tree.copy.edges.from(tree.other).map(\.id) == [tree.edge])
        let moved = try #require(try await tree.copy.edges.to(tree.child).first)
        #expect(moved.id == tree.edge)
        #expect(moved.sourceId == tree.other)
        #expect(moved.targetId == tree.child)
        #expect(moved.edgeType == "parent-of")
        await tree.copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aMoveToAnItemNotYetSentWaitsForItsCreate(kind: CopyKind) async throws {
        let tree = try await Self.tree(kind)
        let held = try #require(try await tree.copy.edges.to(tree.child).first)
        let created = try #require(
            try await tree.copy.queue.all().first { $0.kind == .createItem && $0.itemId == tree.other })

        let write = try #require(
            try await tree.copy.edges.update(
                tree.edge, EdgeEdit(baseVersion: held.version, move: .source(tree.other))))

        #expect(write.dependsOn.contains(created.id), "the move does not wait for the create it names: \(write)")
        await tree.copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEditNamingTheEndTheEdgeHoldsAndAPropertySendsNoEnd(kind: CopyKind) async throws {
        let tree = try await Self.tree(kind)
        let held = try #require(try await tree.copy.edges.to(tree.child).first)

        let write = try #require(
            try await tree.copy.edges.update(
                tree.edge, EdgeEdit(["note": "n"], baseVersion: held.version, move: .source(tree.parent))))

        #expect(write.body["source_id"] == nil, "the end the edge holds was sent: \(write.body)")
        #expect(write.body["properties"] != nil, "the property was not sent: \(write.body)")
        #expect(try await tree.copy.edges.from(tree.parent).map(\.id) == [tree.edge])
        await tree.copy.close()
    }

    @Test(arguments: CopyKind.allCases, [false, true])
    func anEditThatChangesNothingQueuesAndTellsNothing(kind: CopyKind, namingTheHeldEnd: Bool) async throws {
        let tree = try await Self.tree(kind)
        let held = try #require(try await tree.copy.edges.to(tree.child).first)
        let before = try await tree.copy.queue.all()
        let heard = Heard(tree.copy.changes())
        let move: EdgeEdit.Move? = namingTheHeldEnd ? .source(tree.parent) : nil

        let write = try await tree.copy.edges.update(tree.edge, EdgeEdit(baseVersion: held.version, move: move))

        #expect(write == nil)
        #expect(try await tree.copy.queue.all() == before)
        #expect(try await tree.copy.edges.to(tree.child).first == held)
        // The witness: the same edit with a property is queued and told.
        let named = try #require(
            try await tree.copy.edges.update(tree.edge, EdgeEdit(["note": "n"], baseVersion: held.version, move: move)))
        try await eventually("the edit that changed something was told") { !heard.locals.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(heard.locals == [Change(origin: .local(.updateEdge), itemId: named.itemId, edgeId: named.edgeId)])
        #expect(try await tree.copy.queue.all().count == before.count + 1)
        await tree.copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEditThatChangesNothingStillMeetsTheVersionAndTheMissingEdge(kind: CopyKind) async throws {
        let tree = try await Self.tree(kind)
        let held = try #require(try await tree.copy.edges.to(tree.child).first)

        await #expect {
            _ = try await tree.copy.edges.update(tree.edge, EdgeEdit(baseVersion: held.version + 3))
        } throws: { error in
            guard case .invalid(let message)? = error as? MarfaError else { return false }
            return message.contains("version \(held.version + 3)")
        }
        await #expect {
            _ = try await tree.copy.edges.update("missing", EdgeEdit(baseVersion: 1))
        } throws: { error in
            if case .notFound? = error as? MarfaError { true } else { false }
        }
        await tree.copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func propertiesMergeOverTheOnesNotGivenAndTravelWithAMove(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let a = try await Self.note("a", in: copy)
        let b = try await Self.note("b", in: copy)
        let c = try await Self.note("c", in: copy)
        let edge = try #require(
            try await copy.edges.create(from: a, to: c, type: "parent-of", properties: ["note": "first", "kept": 1])
                .edgeId)
        let held = try #require(try await copy.edges.from(a).first)

        _ = try await copy.edges.update(
            edge, EdgeEdit(["note": "second"], baseVersion: held.version, move: .source(b)))

        let read = try #require(try await copy.edges.to(c).first)
        #expect(read.sourceId == b)
        #expect(read.properties == ["note": "second", "kept": 1])
        #expect(try await copy.edges.from(a).isEmpty)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aMoveThatClosesALoopIsRefusedAndQueuesNothing(kind: CopyKind) async throws {
        let tree = try await Self.tree(kind)
        let held = try #require(try await tree.copy.edges.to(tree.child).first)
        let before = try await tree.copy.queue.all()

        await #expect(
            performing: {
                _ = try await tree.copy.edges.update(
                    tree.edge, EdgeEdit(baseVersion: held.version, move: .source(tree.child)))
            }, throws: refused(with: "edge_cycle"))

        #expect(try await tree.copy.queue.all() == before)
        #expect(try await tree.copy.edges.to(tree.child).first == held)
        await tree.copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aMoveOfAnEndWhoseOtherEndHoldsManyIsRefusedAndQueuesNothing(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let a = try await Self.note("a", in: copy)
        let b = try await Self.note("b", in: copy)
        let c = try await Self.note("c", in: copy)
        let edge = try #require(try await copy.edges.create(from: a, to: b, type: "about").edgeId)
        let held = try #require(try await copy.edges.from(a).first)
        let before = try await copy.queue.all()

        await #expect(
            performing: {
                _ = try await copy.edges.update(edge, EdgeEdit(baseVersion: held.version, move: .target(c)))
            }, throws: refused(with: "validation_error"))

        #expect(try await copy.queue.all() == before)
        #expect(try await copy.edges.from(a).first == held)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEditAtAnotherVersionThanTheCopyHoldsIsRefusedAndQueuesNothing(kind: CopyKind) async throws {
        let tree = try await Self.tree(kind)
        let held = try #require(try await tree.copy.edges.to(tree.child).first)
        let before = try await tree.copy.queue.all()

        await #expect {
            _ = try await tree.copy.edges.update(
                tree.edge, EdgeEdit(baseVersion: held.version + 3, move: .source(tree.other)))
        } throws: { error in
            guard case .invalid(let message)? = error as? MarfaError else { return false }
            return message.contains("version \(held.version + 3)")
        }

        #expect(try await tree.copy.queue.all() == before)
        #expect(try await tree.copy.edges.from(tree.parent).map(\.id) == [tree.edge])
        await tree.copy.close()
    }

    // MARK: The move check

    /// What the move check and the update say about the same move, as the error each threw, or `nil` where it
    /// returned; and how many writes the check queued.
    static func checked(
        _ copy: WorkingCopy, _ edge: String, _ move: EdgeEdit.Move
    ) async throws -> (check: MarfaError?, update: MarfaError?, queuedByCheck: Int) {
        let before = try await copy.queue.all().count
        let check = await failure { try await copy.edges.check(edge, moving: move) }
        let queuedByCheck = try await copy.queue.all().count - before
        let held = try #require(try await copy.edges.get(edge))
        let update = await failure {
            _ = try await copy.edges.update(edge, EdgeEdit(baseVersion: held.version, move: move))
        }
        return (check, update, queuedByCheck)
    }

    static func failure(_ call: () async throws -> Void) async -> MarfaError? {
        do {
            try await call()
            return nil
        } catch {
            return error as? MarfaError
        }
    }

    @Test(arguments: CopyKind.allCases)
    func theMoveCheckRefusesAMoveOntoAFullEndAndAllowsAFreeOne(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let newer = try await Self.note("newer", in: copy)
        let old = try await Self.note("old", in: copy)
        let other = try await Self.note("other", in: copy)
        let another = try await Self.note("another", in: copy)
        let free = try await Self.note("free", in: copy)
        let edge = try #require(try await copy.edges.create(from: newer, to: old, type: "supersedes").edgeId)
        _ = try await copy.edges.create(from: other, to: another, type: "supersedes")

        // `other` already supersedes one item and `another` is superseded by one.
        let ontoSource = try await Self.checked(copy, edge, .source(other))
        #expect(ontoSource.queuedByCheck == 0)
        #expect(ontoSource.check == ontoSource.update)
        guard case .validation("edge_constraint_violation", _, let details)? = ontoSource.check else {
            Issue.record("a move onto a full source was answered \(String(describing: ontoSource.check))")
            return
        }
        #expect(
            details == .object(["edge_type": "supersedes", "source_id": .string(other), "constraint": "cardinality"]))
        guard case .object(let read)? = details else { return }
        #expect(read["constraint"] == "cardinality")

        let ontoTarget = try await Self.checked(copy, edge, .target(another))
        #expect(ontoTarget.check == ontoTarget.update)
        guard case .validation("edge_constraint_violation", _, let targetDetails)? = ontoTarget.check else {
            Issue.record("a move onto a full target was answered \(String(describing: ontoTarget.check))")
            return
        }
        #expect(
            targetDetails
                == .object(["edge_type": "supersedes", "target_id": .string(another), "constraint": "cardinality"]))
        #expect(try await copy.edges.from(newer).map(\.targetId) == [old], "a refused move moved the edge")

        // The edge itself is left out: the end that stays holds only it.
        let before = try await copy.queue.all().count
        try await copy.edges.check(edge, moving: .target(free))
        try await copy.edges.check(edge, moving: .source(free))
        try await copy.edges.check(edge, moving: .target(old))
        #expect(try await copy.queue.all().count == before, "the check queued a write")
        let held = try #require(try await copy.edges.get(edge))
        let moved = try await copy.edges.update(edge, EdgeEdit(baseVersion: held.version, move: .target(free)))
        #expect(moved?.kind == .updateEdge, "the update refused a move the check allowed")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func theMoveCheckAnswersAsTheUpdateForEveryOtherRefusal(kind: CopyKind) async throws {
        let tree = try await Self.tree(kind)
        let loop = try await Self.checked(tree.copy, tree.edge, .source(tree.child))
        #expect(loop.check == loop.update)
        guard case .validation("edge_cycle", _, let details)? = loop.check else {
            Issue.record("a move that loops was answered \(String(describing: loop.check))")
            return
        }
        #expect(details == .object(["edge_type": "parent-of"]))
        let many = try await Self.checked(tree.copy, tree.edge, .target(tree.other))
        #expect(many.check == many.update)
        guard case .validation("validation_error", _, nil)? = many.check else {
            Issue.record("a move of an end whose other end holds many was answered \(String(describing: many.check))")
            return
        }
        #expect(loop.queuedByCheck == 0 && many.queuedByCheck == 0)
        await #expect {
            try await tree.copy.edges.check("missing", moving: .source(tree.other))
        } throws: { error in
            if case .notFound("edge_not_found", _)? = error as? MarfaError { true } else { false }
        }
        await tree.copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aMoveOfAnEdgeTheCopyDoesNotHoldIsNotFound(kind: CopyKind) async throws {
        let copy = try await kind.open()
        await #expect {
            _ = try await copy.edges.update("missing", EdgeEdit(baseVersion: 1, move: .source("a")))
        } throws: { error in
            if case .notFound? = error as? MarfaError { true } else { false }
        }
        await copy.close()
    }
}
#endif
