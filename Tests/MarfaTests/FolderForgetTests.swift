#if os(macOS)
import Foundation
import MarfaCore
import Testing

@testable import Marfa

/// The core finds each folder and hold again by the paths it showed, so the preview must come back to it unchanged.
@Test(arguments: ["/volumes/old/notes", "/", "/Volumes/Old Disk/Notes #1 50%?", "/Users/me/Café/ノート"])
func whatRememberingShowedComesBackToTheCoreUnchanged(gone: String) {
    let shown = MarfaCore.Remembered(
        dir: gone, listed: false,
        folders: [
            MarfaCore.RememberingFolder(
                dir: "/work/notes", folder: "folder-a", store: "1:2:store-a",
                held: [
                    MarfaCore.WaitingHeldFile(
                        path: "held.md", item: "item-a", missingSince: "2026-01-01T00:00:00Z",
                        reason: "the folder \(gone) cannot be reached", stillWaitsOn: ["/volumes/other/notes", gone])
                ])
        ],
        notRead: [MarfaCore.FolderLeft(dir: "/work/locked dir", reason: "its saved state cannot be read")],
        alike: ["/volumes/old/Notes"])
    let remembered = Remembered(shown)
    #expect(remembered.core == shown)
    #expect(remembered.directory.path(percentEncoded: false).hasPrefix(gone))
    #expect(remembered.folders.first?.held.first?.stillWaitsOn.count == 2)
}

@Test func aForgetCarriesEveryFolderAndHoldItReports() {
    let forgotten = Forgotten(
        MarfaCore.Forgotten(
            dir: "/volumes/old/notes", listed: false,
            forgotten: [
                MarfaCore.ForgottenIn(
                    dir: "/work/notes", folder: "folder-a", released: ["a.md"],
                    stillHeld: [MarfaCore.StillHeldFile(path: "b.md", stillWaitsOn: ["/volumes/other/notes"])],
                    notReleased: ["c.md"])
            ],
            notChanged: [MarfaCore.FolderLeft(dir: "/work/moved", reason: "its store has moved")]))
    let directory = { (path: String) in URL(filePath: path, directoryHint: .isDirectory) }
    #expect(
        forgotten
            == Forgotten(
                directory: directory("/volumes/old/notes"), listed: false,
                forgotten: [
                    ForgottenIn(
                        directory: directory("/work/notes"), folderId: "folder-a", released: ["a.md"],
                        stillHeld: [StillHeldFile(path: "b.md", stillWaitsOn: [directory("/volumes/other/notes")])],
                        notReleased: ["c.md"])
                ],
                notChanged: [FolderLeft(directory: directory("/work/moved"), reason: "its store has moved")]))
}
#endif
