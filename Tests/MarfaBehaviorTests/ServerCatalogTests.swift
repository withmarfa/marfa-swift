#if DEBUG
import Foundation
import Marfa
import MarfaTesting
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerCatalogOffline {
    @Test(arguments: CopyKind.allCases)
    func aCopyWithoutAServerCannotReadItsCatalog(kind: CopyKind) async throws {
        let copy = try await kind.open()
        await #expect {
            _ = try await copy.catalog.fromServer()
        } throws: { error in
            if case .noServer? = error as? MarfaError { true } else { false }
        }
        #expect(!(try await copy.catalog.itemTypes()).isEmpty, "the copy's own catalog still answers")
        await copy.close()
    }

    @Test func theFakeRefusesToAddAFileInsteadOfAnsweringDifferently() async throws {
        let copy = try await CopyKind.fake.open()
        await #expect {
            _ = try await copy.items.addFile(URL(filePath: "/tmp/none"))
        } throws: { error in (error as? FakeCopyError) == .unsupported(call: "addFile") }
        await copy.close()
    }
}
#endif
