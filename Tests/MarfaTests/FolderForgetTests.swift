#if os(macOS)
import Foundation
import MarfaCore
import Testing

@testable import Marfa

/// The core finds each folder and hold again by the exact bytes of the paths it showed, so the preview must reach it
/// byte for byte as it gave it.
@Test(arguments: [
    "/", "/Volumes/Old/Notes\u{0600}", "/Users/me/Caf\u{E9}", "/Users/me/Cafe\u{301}",
    "/Volumes/Old Disk/Notes #1 50%?", "/volumes/old/notes",
])
func whatRememberingShowedReachesTheCoreByteForByte(gone: String) {
    let shown = MarfaCore.Remembered(
        dir: gone, listed: false,
        folders: [
            MarfaCore.RememberingFolder(
                dir: gone, folder: "folder-a", store: "1:2:store-a",
                held: [
                    MarfaCore.WaitingHeldFile(
                        path: "held.md", item: "item-a", missingSince: "2026-01-01T00:00:00Z",
                        reason: "the folder \(gone) cannot be reached", stillWaitsOn: ["/volumes/other/notes", gone])
                ])
        ],
        notRead: [MarfaCore.FolderLeft(dir: gone, reason: "its saved state cannot be read")],
        alike: [gone])
    var given: [UInt8] = []
    FfiConverterTypeRemembered.write(shown, into: &given)
    var received: [UInt8] = []
    FfiConverterTypeRemembered.write(Remembered(shown).core, into: &received)
    #expect(received == given)
}

/// A scripted value's directory reaches the core without the slash a directory URL adds, even where the slash joins
/// the character before it in one grapheme.
@Test(arguments: ["/", "/Volumes/Old/Notes", "/Volumes/Old/Notes\u{0600}", "/Volumes/Old Disk/Notes #1 50%?"])
func aScriptedDirectoryReachesTheCoreWithoutItsSlash(gone: String) {
    let scripted = Remembered(directory: URL(filePath: gone, directoryHint: .isDirectory), listed: false, folders: [])
    #expect(Array(scripted.core.dir.utf8) == Array(gone.utf8))
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
