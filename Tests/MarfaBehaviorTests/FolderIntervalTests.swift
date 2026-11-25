#if DEBUG
import Marfa
import MarfaTesting
import Testing

@Suite(.timeLimit(.minutes(1)))
struct FolderIntervalTests {
    @Test(arguments: CopyKind.allCases)
    func invalidIntervalsAreRefusedBeforeWriting(kind: CopyKind) async throws {
        let copy = try await kind.open()
        for interval: UInt64 in [59, 86_401, .max] {
            await #expect {
                try await copy.createFolder(FolderSettings(title: "Interval", fullPassIntervalSeconds: interval))
            } throws: { error in
                if case .invalid = error as? MarfaError { true } else { false }
            }
            await #expect {
                try await copy.changeFolder(
                    "01a00000-0000-7000-8000-000000000001", FolderSettingsChange(fullPassIntervalSeconds: interval),
                    baseVersion: 1)
            } throws: { error in
                if case .invalid = error as? MarfaError { true } else { false }
            }
        }
        #expect(try await copy.queue.all().isEmpty)
        await copy.close()
    }
}
#endif
