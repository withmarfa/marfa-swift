#if os(macOS)
import Foundation
import MarfaCore
import Testing

@testable import Marfa

@Test func aRemovalAnswersTheFolderTheUnsentWritesAndEachFileByKind() {
    let core = MarfaCore.FolderRemoval(
        dir: "/Folders/Notes", removed: true, reason: nil, folder: "01a1500d-78bd-73f0-8c55-2a4160c5ff01", unsent: 4,
        files: [
            MarfaCore.UnsentFile(change: .changed, path: "a.md", from: nil, item: "item-a"),
            MarfaCore.UnsentFile(change: .new, path: "b.md", from: nil, item: nil),
            MarfaCore.UnsentFile(change: .moved, path: "d/c.md", from: "c.md", item: "item-c"),
            MarfaCore.UnsentFile(change: .deleted, path: nil, from: nil, item: nil),
        ])

    let removal = FolderRemoval(core)

    #expect(removal.directory == URL(filePath: "/Folders/Notes", directoryHint: .isDirectory))
    #expect(removal.removed && removal.reason == nil)
    #expect(removal.folderId == "01a1500d-78bd-73f0-8c55-2a4160c5ff01")
    #expect(removal.unsent == 4)
    #expect(removal.files.map(\.change) == [.changed, .new, .moved, .deleted])
    #expect(removal.files.map(\.path) == ["a.md", "b.md", "d/c.md", nil])
    #expect(removal.files.map(\.from) == [nil, nil, "c.md", nil])
    #expect(removal.files.map(\.itemId) == ["item-a", nil, "item-c", nil])
}

@Test func aRemovalThatOnlyTookTheRegistryEntryAnswersWhyAndNoFolder() {
    let core = MarfaCore.FolderRemoval(
        dir: "/Folders/Gone", removed: false, reason: "the directory is gone", folder: nil, unsent: 0, files: [])

    let removal = FolderRemoval(core)

    #expect(!removal.removed && removal.reason == "the directory is gone")
    #expect(removal.folderId == nil && removal.unsent == 0 && removal.files.isEmpty)
}
#endif
