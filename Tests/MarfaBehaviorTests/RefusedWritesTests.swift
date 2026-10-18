#if DEBUG
import Foundation
import Marfa
import MarfaTesting
import Testing

/// What a copy shows after the server refuses a write.
///
/// The real copy gets its refusal from a booted server, so it runs only where
/// `MARFA_API_URL` and `MARFA_API_KEY` name one; with `MARFA_LIVE_REQUIRED` a
/// missing server fails `theLiveBehaviorTestsHaveAServerWhereTheyAreRequired` instead of
/// skipping. The fake gets the same refusal from its verdict chooser, and both
/// must show the same rows.
@Suite(.timeLimit(.minutes(2)))
struct RefusedWrites {
    /// What a test sees of a copy after a refused move, with ids named by the
    /// item they belong to.
    struct Seen: Equatable {
        var shownBeforeTheAnswer: [String]
        var refusalCode: String?
        var edgesInto: [String: [String]]
        var edgesOutOfC: [String]
    }

    /// Moves the source of the edge from `a` to `b` onto `c`, which closes the loop b, c, b.
    ///
    /// `a` holds `b` and `b` holds `c`, both answered before the move.
    static func refusedMove(on copy: WorkingCopy) async throws -> Seen {
        func note(_ title: String) async throws -> String {
            try #require(
                try await copy.items.create(
                    Draft(
                        type: "core.note", properties: ["title": .string("\(title) \(UUID())"), "body": "b"],
                        tier: .feed)
                ).itemId)
        }
        let a = try await note("a")
        let b = try await note("b")
        let c = try await note("c")
        let ab = try #require(try await copy.edges.create(from: a, to: b, type: "parent-of").edgeId)
        _ = try await copy.edges.create(from: b, to: c, type: "parent-of")
        let setup = try await copy.queue.drain()
        #expect(setup.verdicts.allSatisfy { $0.verdict == .accepted }, "\(setup.verdicts)")
        let held = try #require(try await copy.edges.from(a).first)
        let names = [a: "a", b: "b", c: "c"]
        func named(_ ids: [String]) -> [String] { ids.map { names[$0] ?? $0 } }

        let move = try #require(
            try await copy.edges.update(ab, EdgeEdit(baseVersion: held.version, move: .source(c))))
        let shown = try await copy.edges.from(c).map(\.id)
        let report = try await copy.queue.drain()

        var code: String?
        if case .refused(let refusal)? = report.verdicts.first(where: { $0.id == move.id })?.verdict {
            code = refusal.code
        }
        return Seen(
            shownBeforeTheAnswer: shown == [ab] ? ["the edge"] : [],
            refusalCode: code,
            edgesInto: [
                "b": named(try await copy.edges.to(b).map(\.sourceId)),
                "c": named(try await copy.edges.to(c).map(\.sourceId)),
            ],
            edgesOutOfC: named(try await copy.edges.from(c).map(\.targetId)))
    }

    static let afterwards = Seen(
        shownBeforeTheAnswer: ["the edge"], refusalCode: "edge_cycle", edgesInto: ["b": ["a"], "c": ["b"]],
        edgesOutOfC: [])

    @Test(arguments: CopyKind.allCases)
    func aMoveTheServerRefusesPutsTheEdgeBackAsItWasBeforeTheMove(kind: CopyKind) async throws {
        let seen: Seen
        switch kind {
        case .real:
            guard let server = LiveServer.server else {
                try Test.cancel("set MARFA_API_URL and MARFA_API_KEY to run against a server")
                return
            }
            let copy = try await WorkingCopy.open(store: temporaryStore(), server: server)
            _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
            seen = try await Self.refusedMove(on: copy)
            await copy.close()
        case .fake:
            let fake = try await CopyKind.makeFake()
            fake.verdict = { write in
                write.kind == .updateEdge ? .refused(Refusal(reason: "edge_cycle", code: "edge_cycle")) : .accepted
            }
            seen = try await Self.refusedMove(on: fake.copy)
            await fake.copy.close()
        }
        #expect(seen == Self.afterwards)
    }
}

@Test(.enabled(if: LiveServer.isRequired), .timeLimit(.minutes(1)))
func theLiveBehaviorTestsHaveAServerWhereTheyAreRequired() {
    #expect(LiveServer.server != nil, "MARFA_LIVE_REQUIRED is set, and MARFA_API_URL or MARFA_API_KEY is not")
}
#endif
