#if DEBUG
import Marfa
import MarfaTesting
import Testing

@Suite(.timeLimit(.minutes(1)))
struct FolderIntervalTests {
    @Test func aScriptedFolderReceivesAndReturnsBothBounds() async throws {
        let fake = WorkingCopy.fake()
        let initial = FolderSettings(title: "Interval", fullPassIntervalSeconds: 60)
        let row = Folder(id: "folder", version: 1, state: .active, settings: initial)
        var script = FolderSettingsScript()
        script.create = { settings, key in
            #expect(settings == initial && key == "create")
            return row
        }
        script.read = { id in id == row.id ? row : nil }
        script.change = { id, change, version, key in
            #expect(id == row.id && version == 1 && key == "change")
            #expect(change == FolderSettingsChange(fullPassIntervalSeconds: 86_400))
            var settings = initial
            settings.fullPassIntervalSeconds = change.fullPassIntervalSeconds
            return Folder(id: id, version: 2, state: .active, settings: settings)
        }
        fake.folderSettings = script
        #expect(try await fake.copy.createFolder(initial, idempotencyKey: "create") == row)
        #expect(try await fake.copy.items.folder(row.id) == row)
        let result = try await fake.copy.changeFolder(
            row.id, FolderSettingsChange(fullPassIntervalSeconds: 86_400), baseVersion: 1, idempotencyKey: "change")
        #expect(result.settings.fullPassIntervalSeconds == 86_400)
    }

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
