import Foundation
import Testing

@testable import Marfa

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(1)))
    struct LiveQueue {
        /// Two answered creates and the report that answered them.
        static func answeredPair(_ copy: WorkingCopy) async throws -> (first: QueuedWrite, second: QueuedWrite) {
            let first = try await copy.items.create(Live.note("first \(UUID())"))
            let second = try await copy.items.create(Live.note("second \(UUID())"))
            let report = try await copy.queue.drain()
            #expect(report.verdicts.map(\.verdict) == [.accepted, .accepted], "\(report.verdicts)")
            return (first, second)
        }

        @Test func aNamedAnsweredWriteIsForgottenAndAnotherAnsweredWriteStays() async throws {
            let copy = try await Live.hydrated()
            let (first, second) = try await Self.answeredPair(copy)

            #expect(try await copy.queue.forgetAnswered(ids: [first.id]) == 1)

            let held = try await copy.queue.all()
            #expect(held.map(\.id) == [second.id], "\(held)")
            #expect(held.first?.verdict == .accepted)
            await copy.close()
        }

        @Test func anEmptyListForgetsNothing() async throws {
            let copy = try await Live.hydrated()
            let (first, second) = try await Self.answeredPair(copy)

            #expect(try await copy.queue.forgetAnswered(ids: []) == 0)

            #expect(Set(try await copy.queue.all().map(\.id)) == [first.id, second.id])
            await copy.close()
        }

        @Test func aNamedWriteTheServerHasNotAnsweredIsKept() async throws {
            let copy = try await Live.hydrated()
            let answered = try await copy.items.create(Live.note("answered \(UUID())"))
            _ = try await copy.queue.drain()
            let unanswered = try await copy.items.create(Live.note("unanswered \(UUID())"))

            #expect(try await copy.queue.forgetAnswered(ids: [unanswered.id, answered.id, "no-such-write"]) == 1)

            let held = try await copy.queue.all()
            #expect(held.map(\.id) == [unanswered.id], "\(held)")
            #expect(held.first?.verdict == nil)
            await copy.close()
        }
    }
}
