#if DEBUG
import Foundation
import Marfa
import MarfaTesting
import Testing

/// What a stream of the copy hears when the queue is cleared.
///
/// A real copy with no server answers no write, so the tests that need an
/// answered write run on it only where `MARFA_API_URL` and `MARFA_API_KEY` name
/// a server, and the tests that need a refusal run on the fake alone. What
/// clears nothing runs on both with no server.
@MainActor @Suite(.timeLimit(.minutes(2)))
struct QueueClearing {
    enum Clearing: CaseIterable, Sendable, CustomTestStringConvertible {
        case everyAnswer
        case namedAnswers
        case takenAnswers

        var testDescription: String {
            switch self {
            case .everyAnswer: "forgetAnswered()"
            case .namedAnswers: "forgetAnswered(ids:)"
            case .takenAnswers: "takeAnswered()"
            }
        }

        func run(_ copy: WorkingCopy, answered: [String]) async throws -> UInt64 {
            switch self {
            case .everyAnswer: try await copy.queue.forgetAnswered()
            case .namedAnswers: try await copy.queue.forgetAnswered(ids: answered)
            case .takenAnswers: UInt64(try await copy.queue.takeAnswered().count)
            }
        }
    }

    static func note(_ copy: WorkingCopy) async throws -> QueuedWrite {
        try await copy.items.create(
            Draft(type: "core.note", properties: ["title": .string("n \(UUID())"), "body": "b"], tier: .feed))
    }

    static var forgotten: Change { Change(origin: .refreshed(.forgotten), itemId: nil, edgeId: nil) }

    /// A copy where drains answer, and the answered write it queued.
    static func answered(_ kind: CopyKind) async throws -> (WorkingCopy, QueuedWrite)? {
        guard let (copy, writes) = try await answered(kind, count: 1) else { return nil }
        return (copy, writes[0])
    }

    /// A copy where drains answer, and the `count` answered writes it queued.
    static func answered(_ kind: CopyKind, count: Int) async throws -> (WorkingCopy, [QueuedWrite])? {
        let copy: WorkingCopy
        switch kind {
        case .real:
            guard let server = LiveServer.server else {
                try Test.cancel("set MARFA_API_URL and MARFA_API_KEY to run against a server")
                return nil
            }
            copy = try await WorkingCopy.open(store: temporaryStore(), server: server)
            _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
        case .fake:
            copy = try await kind.open()
        }
        var writes: [QueuedWrite] = []
        for _ in 0..<count { writes.append(try await note(copy)) }
        let report = try await copy.queue.drain()
        #expect(report.verdicts.map(\.verdict) == Array(repeating: .accepted, count: count), "\(report.verdicts)")
        return (copy, writes)
    }

    @Test(arguments: CopyKind.allCases, Clearing.allCases)
    func aQueueReadingLosesTheClearedAnswersWithNoRefresh(kind: CopyKind, clearing: Clearing) async throws {
        guard let (copy, write) = try await Self.answered(kind) else { return }
        let query = LiveQuery(copy, reading: .queue)
        try await eventually("the answered write shows") { query.value.map(\.id) == [write.id] }

        #expect(try await clearing.run(copy, answered: [write.id]) == 1)

        try await eventually("the cleared write left") { query.value.isEmpty }
        #expect(query.error == nil)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aQueueReadingLosesADiscardedWriteWithNoRefresh(kind: CopyKind) async throws {
        guard kind == .fake else {
            try Test.cancel("a real copy is refused a write only by a server")
            return
        }
        let fake = try await CopyKind.makeFake()
        fake.verdict = { _ in .refused(Refusal(reason: "no", code: "no")) }
        let copy = fake.copy
        let write = try await Self.note(copy)
        _ = try await copy.queue.drain()
        let query = LiveQuery(copy, reading: .queue)
        try await eventually("the refused write shows") { query.value.map(\.id) == [write.id] }

        #expect(try await copy.queue.discard(write.id))

        try await eventually("the discarded write left") { query.value.isEmpty }
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func clearingNothingAnnouncesNothing(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let unanswered = try await Self.note(copy)
        let heard = Heard(copy.changes())

        #expect(try await copy.queue.forgetAnswered() == 0)
        #expect(try await copy.queue.forgetAnswered(ids: [unanswered.id, "absent"]) == 0)
        #expect(try await copy.queue.forgetAnswered(ids: []) == 0)
        #expect(try await copy.queue.takeAnswered().isEmpty)
        #expect(try await copy.queue.discard(unanswered.id) == false)
        // Told in order, so a change the calls above made would come before this one.
        let sentinel = try await Self.note(copy)
        try await eventually("the sentinel was told") { heard.locals.count == 1 }

        #expect(!heard.all.contains(Self.forgotten), "\(heard.all)")
        #expect(try await copy.queue.all().map(\.id) == [unanswered.id, sentinel.id])
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases, Clearing.allCases)
    func clearingAnAnswerIsToldOnce(kind: CopyKind, clearing: Clearing) async throws {
        guard let (copy, write) = try await Self.answered(kind) else { return }
        let heard = Heard(copy.changes())

        #expect(try await clearing.run(copy, answered: [write.id]) == 1)
        #expect(try await clearing.run(copy, answered: [write.id]) == 0)
        let sentinel = try await Self.note(copy)
        try await eventually("the sentinel was told") { heard.locals.count == 1 }

        #expect(heard.all.filter { $0 == Self.forgotten }.count == 1, "\(heard.all)")
        #expect(try await copy.queue.all().map(\.id) == [sentinel.id])
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func takingAnswersReturnsThemAsTheQueueShowedThemAndLeavesTheRest(kind: CopyKind) async throws {
        guard let (copy, writes) = try await Self.answered(kind, count: 2) else { return }
        let unanswered = try await Self.note(copy)
        let shown = try await copy.queue.all()

        let taken = try await copy.queue.takeAnswered()

        #expect(taken == shown.filter { $0.id != unanswered.id })
        #expect(Set(taken.map(\.id)) == Set(writes.map(\.id)))
        #expect(try await copy.queue.all().map(\.id) == [unanswered.id])
        #expect(try await copy.queue.takeAnswered().isEmpty)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func twoTakersAtOnceGetDisjointAnswersThatCoverEveryOne(kind: CopyKind) async throws {
        guard let (copy, writes) = try await Self.answered(kind, count: 6) else { return }
        let queue = copy.queue

        let (first, second) = try await withThrowingTaskGroup(of: [QueuedWrite].self) { group in
            group.addTask { try await queue.takeAnswered() }
            group.addTask { try await queue.takeAnswered() }
            let first = try await group.next() ?? []
            let second = try await group.next() ?? []
            return (first, second)
        }

        let firstIds = Set(first.map(\.id))
        let secondIds = Set(second.map(\.id))
        #expect(firstIds.isDisjoint(with: secondIds), "both takers got \(firstIds.intersection(secondIds))")
        #expect(firstIds.union(secondIds) == Set(writes.map(\.id)))
        #expect(first.count + second.count == writes.count)
        #expect(try await copy.queue.all().isEmpty)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func takingKeepsARefusedWriteThatCarriedContent(kind: CopyKind) async throws {
        guard kind == .fake else {
            try Test.cancel("a real copy is refused a write only by a server")
        }
        let fake = try await CopyKind.makeFake()
        let copy = fake.copy
        let accepted = try await Self.note(copy)
        _ = try await copy.queue.drain()
        fake.verdict = { _ in .refused(Refusal(reason: "no", code: "no")) }
        let refused = try await Self.note(copy)
        _ = try await copy.queue.drain()

        #expect(try await copy.queue.takeAnswered().map(\.id) == [accepted.id])
        #expect(try await copy.queue.all().map(\.id) == [refused.id])
        #expect(try await copy.queue.discard(refused.id))
        await copy.close()
    }
}
#endif
