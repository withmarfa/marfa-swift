#if DEBUG
import Marfa
import Testing

@Suite struct TransitionFrom {
    @Test(arguments: CopyKind.allCases)
    func aStaleTransitionKeepsTheItemAndQueue(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let id = try await ItemsOffline.note("Story", in: copy)
        _ = try await copy.items.transition(id, to: .archived)
        let before = try await copy.queue.all()
        await #expect {
            _ = try await copy.items.transition(id, to: .trashed, from: .active)
        } throws: { error in
            guard case .validation("state_conflict", let message, let details, nil)? = error as? MarfaError else {
                return false
            }
            return message.contains("\(id) is archived, not active")
                && details?.object == ["expected": "active", "actual": "archived"]
        }
        #expect(try await copy.queue.all() == before)
        #expect(try await copy.items.get(id)?.state == .archived)
        let write = try await copy.items.transition(id, to: .trashed, from: .archived)
        #expect(write.body == ["state": "trashed", "from": "archived"])
        await copy.close()
    }
}
#endif
