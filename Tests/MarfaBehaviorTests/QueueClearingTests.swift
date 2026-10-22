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

        var testDescription: String {
            switch self {
            case .everyAnswer: "forgetAnswered()"
            case .namedAnswers: "forgetAnswered(ids:)"
            }
        }

        func run(_ copy: WorkingCopy, answered: [String]) async throws -> UInt64 {
            switch self {
            case .everyAnswer: try await copy.queue.forgetAnswered()
            case .namedAnswers: try await copy.queue.forgetAnswered(ids: answered)
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
        let write = try await note(copy)
        let report = try await copy.queue.drain()
        #expect(report.verdicts.map(\.verdict) == [.accepted], "\(report.verdicts)")
        return (copy, write)
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
}
#endif
