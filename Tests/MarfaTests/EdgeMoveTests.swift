import Foundation
import Testing

@testable import Marfa

private func refused(with code: String) -> (any Error) -> Bool {
    { error in
        if case .validation(let given, _)? = error as? MarfaError { given == code } else { false }
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
    static func tree() async throws -> Tree {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let parent = try await note("parent", in: copy)
        let other = try await note("other", in: copy)
        let child = try await note("child", in: copy)
        let edge = try #require(try await copy.edges.create(from: parent, to: child, type: "parent-of").edgeId)
        return Tree(copy: copy, parent: parent, other: other, child: child, edge: edge)
    }

    @Test func aMovedSourceShowsAtOnceAtItsNewEndAndQueuesOneWrite() async throws {
        let tree = try await Self.tree()
        let held = try #require(try await tree.copy.edges.to(tree.child).first)
        let before = try await tree.copy.queue.all().count

        let write = try await tree.copy.edges.update(
            tree.edge, EdgeEdit(baseVersion: held.version, move: .source(tree.other)))

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

    @Test func aMoveToAnItemNotYetSentWaitsForItsCreate() async throws {
        let tree = try await Self.tree()
        let held = try #require(try await tree.copy.edges.to(tree.child).first)
        let created = try #require(
            try await tree.copy.queue.all().first { $0.kind == .createItem && $0.itemId == tree.other })

        let write = try await tree.copy.edges.update(
            tree.edge, EdgeEdit(baseVersion: held.version, move: .source(tree.other)))

        #expect(write.dependsOn.contains(created.id), "the move does not wait for the create it names: \(write)")
        await tree.copy.close()
    }

    @Test func anEditNamingTheEndTheEdgeHoldsSendsNoEnd() async throws {
        let tree = try await Self.tree()
        let held = try #require(try await tree.copy.edges.to(tree.child).first)

        let write = try await tree.copy.edges.update(
            tree.edge, EdgeEdit(baseVersion: held.version, move: .source(tree.parent)))

        #expect(write.body["source_id"] == nil, "the end the edge holds was sent: \(write.body)")
        #expect(try await tree.copy.edges.from(tree.parent).map(\.id) == [tree.edge])
        await tree.copy.close()
    }

    @Test func propertiesMergeOverTheOnesNotGivenAndTravelWithAMove() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
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

    @Test func aMoveThatClosesALoopIsRefusedAndQueuesNothing() async throws {
        let tree = try await Self.tree()
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

    @Test func aMoveOfAnEndWhoseOtherEndHoldsManyIsRefusedAndQueuesNothing() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
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

    @Test func anEditAtAnotherVersionThanTheCopyHoldsIsRefusedAndQueuesNothing() async throws {
        let tree = try await Self.tree()
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

    @Test func aMoveOfAnEdgeTheCopyDoesNotHoldIsNotFound() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        await #expect {
            _ = try await copy.edges.update("missing", EdgeEdit(baseVersion: 1, move: .source("a")))
        } throws: { error in
            if case .notFound? = error as? MarfaError { true } else { false }
        }
        await copy.close()
    }
}
