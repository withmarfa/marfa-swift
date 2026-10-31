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

    /// Four items and the `parent-of` edges `a` to `b`, `b` to a task and the task to `c`, all answered.
    struct Chain {
        var a: String
        var b: String
        var c: String
        var ab: String
    }

    /// The loop b, task, c, b runs through a task, which a copy that hydrates only notes does not hold.
    ///
    /// The fake holds every row, so it would refuse the move itself, as the core refuses a loop it holds. It is
    /// given no edge through the task, so that it too sees nothing wrong and the verdict chooser refuses.
    static func chain(on builder: WorkingCopy, throughTheTask: Bool = true) async throws -> Chain {
        func create(_ type: String, _ title: String) async throws -> String {
            try #require(
                try await builder.items.create(
                    Draft(type: type, properties: ["title": .string("\(title) \(UUID())")], tier: .feed)
                ).itemId)
        }
        let a = try await create("core.note", "a")
        let b = try await create("core.note", "b")
        let c = try await create("core.note", "c")
        let between = try await create("core.task", "between")
        let ab = try #require(try await builder.edges.create(from: a, to: b, type: "parent-of").edgeId)
        if throughTheTask {
            _ = try await builder.edges.create(from: b, to: between, type: "parent-of")
            _ = try await builder.edges.create(from: between, to: c, type: "parent-of")
        }
        let setup = try await builder.queue.drain()
        #expect(setup.verdicts.allSatisfy { $0.verdict == .accepted }, "\(setup.verdicts)")
        return Chain(a: a, b: b, c: c, ab: ab)
    }

    /// Moves the source of the edge from `a` to `b` onto `c`, which closes the loop that only the chain's
    /// task connects, so the copy cannot refuse it itself.
    static func refusedMove(on copy: WorkingCopy, chain: Chain) async throws -> Seen {
        let (a, b, c, ab) = (chain.a, chain.b, chain.c, chain.ab)
        let held = try #require(try await copy.edges.from(a).first)
        let names = [a: "a", b: "b", c: "c"]
        func named(_ ids: [String]) -> [String] { ids.compactMap { names[$0] } }

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
        shownBeforeTheAnswer: ["the edge"], refusalCode: "edge_cycle", edgesInto: ["b": ["a"], "c": []],
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
            let builder = try await WorkingCopy.open(store: temporaryStore(), server: server)
            _ = try await builder.hydrate(types: ["core.note"], tier: .feed)
            let chain = try await Self.chain(on: builder)
            await builder.close()
            let copy = try await WorkingCopy.open(store: temporaryStore(), server: server)
            _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
            seen = try await Self.refusedMove(on: copy, chain: chain)
            await copy.close()
        case .fake:
            let fake = try await CopyKind.makeFake()
            fake.verdict = { write in
                write.kind == .updateEdge ? .refused(Refusal(reason: "edge_cycle", code: "edge_cycle")) : .accepted
            }
            let chain = try await Self.chain(on: fake.copy, throughTheTask: false)
            seen = try await Self.refusedMove(on: fake.copy, chain: chain)
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
