#if DEBUG
import Foundation
import Marfa
import MarfaTesting
import Testing

/// Several-item trash needs the server's preview, so a copy with none refuses it the same way on both copies.
@Suite(.timeLimit(.minutes(1)))
struct SeveralItemTrashOffline {
    @Test(arguments: CopyKind.allCases)
    func aPreviewWithNoServerIsRefusedAndNamingNoItemsOrTooManyIsRefusedFirst(kind: CopyKind) async throws {
        let copy = try await kind.open()
        await #expect {
            _ = try await copy.items.previewTrash(ids: ["a", "b", "a"])
        } throws: { error in
            if case .noServer? = error as? MarfaError { true } else { false }
        }
        for ids in [[], (0..<21).map { "item-\($0)" }] {
            await #expect {
                _ = try await copy.items.previewTrash(ids: ids)
            } throws: { error in
                guard case .validation(let code, _, _, _)? = error as? MarfaError else { return false }
                return code == "validation_error"
            }
        }
        // Twenty distinct items is the most; an ID named again does not count twice.
        let twenty = (0..<20).map { "item-\($0)" }
        for ids in [twenty, twenty + twenty] {
            await #expect {
                _ = try await copy.items.previewTrash(ids: ids)
            } throws: { error in
                if case .noServer? = error as? MarfaError { true } else { false }
            }
        }
        await copy.close()
    }
}
#endif
