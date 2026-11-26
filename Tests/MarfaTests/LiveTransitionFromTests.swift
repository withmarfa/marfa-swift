import Marfa
import Testing

extension LiveWorkingCopies {
    @Suite(.enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"))
    struct LiveTransitionFrom {
        @Test func aQueuedTransitionReportsTheServersConflictMessage() async throws {
            let first = try await Live.hydrated()
            let id = try #require(try await first.items.create(Live.note("Reading")).itemId)
            _ = try await first.queue.drain()
            let second = try await Live.hydrated()
            let archive = try await first.items.transition(id, to: .archived, from: .active)
            _ = try await second.items.transition(id, to: .trashed, from: .active)
            let moved = try await second.queue.drain()
            #expect(moved.verdicts.first?.verdict == .accepted)
            let answered = try await first.queue.drain()
            let verdict = try #require(answered.verdicts.first { $0.id == archive.id }?.verdict)
            guard case .refused(let refusal) = verdict else {
                Issue.record("Expected a state conflict, got \(verdict)")
                return
            }
            #expect(refusal.code == "state_conflict")
            #expect(refusal.message == "The item is trashed, not active. Read it again.")
            await second.close()
            await first.close()
        }
    }
}
