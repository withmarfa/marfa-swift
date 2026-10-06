import Foundation
import Testing

@testable import Marfa

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveEdgeMoves {
        typealias Tree = (parent: String, other: String, child: String, edge: String)

        /// `parent` holds `child` through a `parent-of` edge the server has answered.
        static func tree(in copy: WorkingCopy) async throws -> Tree {
            let parent = try #require(try await copy.items.create(Live.note("moved parent \(UUID())")).itemId)
            let other = try #require(try await copy.items.create(Live.note("moved other \(UUID())")).itemId)
            let child = try #require(try await copy.items.create(Live.note("moved child \(UUID())")).itemId)
            let edge = try #require(try await copy.edges.create(from: parent, to: child, type: "parent-of").edgeId)
            let report = try await copy.queue.drain()
            #expect(report.verdicts.allSatisfy { $0.verdict == .accepted }, "\(report.verdicts)")
            return (parent, other, child, edge)
        }

        /// A source move changes the structural generation of the server's read view (device.md 52), so the read
        /// after its answer expires the copy: the write is answered, and the app hydrates again.
        static func drainAfterASourceMove(_ copy: WorkingCopy) async throws {
            await #expect {
                _ = try await copy.queue.drain()
            } throws: { error in
                if case MarfaError.copyExpired(reason: "read_view_changed", _) = error { true } else { false }
            }
            _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
        }

        static func verdict(of write: QueuedWrite, in copy: WorkingCopy) async throws -> Verdict? {
            try await copy.queue.all().first { $0.id == write.id }?.verdict
        }

        @Test func aNoteMovedToAnotherParentWhileUnsentSurvivesARestartAndIsAcceptedAsOneEdge() async throws {
            let store = Live.store()
            let copy = try await Live.hydrated(store)
            let tree = try await Self.tree(in: copy)
            let held = try #require(try await copy.edges.to(tree.child).first)

            let move = try await copy.edges.update(
                tree.edge, EdgeEdit(baseVersion: held.version, move: .source(tree.other)))
            #expect(try await copy.edges.from(tree.parent).isEmpty)
            #expect(try await copy.edges.from(tree.other).map(\.id) == [tree.edge])
            await copy.close()

            let reopened = try await WorkingCopy.open(store: store, server: Live.server)
            #expect(
                try await reopened.edges.to(tree.child).map(\.sourceId) == [tree.other],
                "the move was not held across a restart")
            try await Self.drainAfterASourceMove(reopened)

            #expect(try await Self.verdict(of: move, in: reopened) == .accepted)
            let answered = try #require(try await reopened.edges.to(tree.child).first)
            #expect(answered.id == tree.edge)
            #expect(answered.sourceId == tree.other)
            #expect(answered.version > held.version)

            let elsewhere = try await Live.hydrated()
            let served = try await elsewhere.edges.to(tree.child)
            #expect(served.map(\.id) == [tree.edge], "the server holds \(served.count) edges to the child")
            #expect(served.first?.sourceId == tree.other)
            #expect(try await elsewhere.edges.from(tree.parent).isEmpty)
            await reopened.close()
            await elsewhere.close()
        }

        @Test func aMoveToANoteCreatedInTheSameBreathWaitsForItsCreate() async throws {
            let copy = try await Live.hydrated()
            let tree = try await Self.tree(in: copy)
            let held = try #require(try await copy.edges.to(tree.child).first)
            let created = try await copy.items.create(Live.note("moved new parent \(UUID())"))
            let newParent = try #require(created.itemId)

            let move = try await copy.edges.update(
                tree.edge, EdgeEdit(baseVersion: held.version, move: .source(newParent)))
            try await Self.drainAfterASourceMove(copy)

            #expect(try await Self.verdict(of: created, in: copy) == .accepted)
            #expect(try await Self.verdict(of: move, in: copy) == .accepted)
            let elsewhere = try await Live.hydrated()
            #expect(try await elsewhere.edges.to(tree.child).map(\.sourceId) == [newParent])
            await copy.close()
            await elsewhere.close()
        }

        @Test func aTargetMoveWithPropertiesIsAcceptedAndLeavesTheCopyCurrent() async throws {
            let copy = try await Live.hydrated()
            let reply = try #require(try await copy.items.create(Live.note("reply \(UUID())")).itemId)
            let first = try #require(try await copy.items.create(Live.note("first thread \(UUID())")).itemId)
            let second = try #require(try await copy.items.create(Live.note("second thread \(UUID())")).itemId)
            let edge = try #require(try await copy.edges.create(from: reply, to: first, type: "in-thread").edgeId)
            let setup = try await copy.queue.drain()
            #expect(setup.verdicts.allSatisfy { $0.verdict == .accepted }, "\(setup.verdicts)")
            let held = try #require(try await copy.edges.from(reply).first)

            let move = try await copy.edges.update(
                edge, EdgeEdit(["note": "moved"], baseVersion: held.version, move: .target(second)))
            let report = try await copy.queue.drain()

            #expect(report.verdicts.first { $0.id == move.id }?.verdict == .accepted, "\(report.verdicts)")
            let now = try #require(try await copy.edges.from(reply).first)
            #expect(now.id == edge)
            #expect(now.targetId == second)
            #expect(now.version > held.version)
            let elsewhere = try await Live.hydrated()
            let served = try #require(try await elsewhere.edges.from(reply).first)
            #expect(served.id == edge)
            #expect(served.targetId == second)
            #expect(served.properties["note"] == "moved")
            #expect(try await elsewhere.edges.to(first).isEmpty)
            await copy.close()
            await elsewhere.close()
        }

        @Test func aMoveOnlyTheServerCanSeeClosesALoopIsRefusedWithItsCodeAndTheEdgeReturns() async throws {
            let copy = try await Live.hydrated()
            let a = try #require(try await copy.items.create(Live.note("loop a \(UUID())")).itemId)
            let b = try #require(try await copy.items.create(Live.note("loop b \(UUID())")).itemId)
            let c = try #require(try await copy.items.create(Live.note("loop c \(UUID())")).itemId)
            let ab = try #require(try await copy.edges.create(from: a, to: b, type: "parent-of").edgeId)
            _ = try await copy.edges.create(from: b, to: c, type: "parent-of")
            let setup = try await copy.queue.drain()
            #expect(setup.verdicts.allSatisfy { $0.verdict == .accepted }, "\(setup.verdicts)")
            let held = try #require(try await copy.edges.from(a).first)

            // c above b closes the cycle b, c, b, which the copy cannot see from the edge alone.
            let move = try await copy.edges.update(ab, EdgeEdit(baseVersion: held.version, move: .source(c)))
            let report = try await copy.queue.drain()

            guard case .refused(let refusal)? = report.verdicts.first(where: { $0.id == move.id })?.verdict else {
                Issue.record("the move was not refused: \(report.verdicts)")
                return
            }
            #expect(refusal.code == "edge_cycle")
            let back = try await copy.edges.to(b).filter { $0.id == ab }
            #expect(back.map(\.sourceId) == [a], "the refused move left the edge at \(back.map(\.sourceId))")
            await copy.close()
        }
    }
}
