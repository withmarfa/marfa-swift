#if os(macOS)
import Foundation
import Marfa
import Testing

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(3)))
    struct LiveFolderForget {
        /// Every other folder listed or remembered also withholds a delete, so the scenario runs in a process of its
        /// own, whose registry holds only its two folders.
        @Test func aDeleteHeldForAGoneFolderIsShownReleasedByForgettingItAndDecidedAgain() async {
            await #expect(processExitsWith: .success) {
                try await forgettingAGoneFolder()
            }
        }
    }
}

private func forgettingAGoneFolder() async throws {
    let folders = FolderFixture.folders
    try #require(try await folders.list().isEmpty, "the registry is this process's own")
    let first = FolderFixture.directory()
    let folderId = try await FolderFixture.settings()
    _ = try await folders.add(first, following: folderId)
    let second = FolderFixture.directory()
    _ = try await folders.add(second, following: try await FolderFixture.settings())
    try await folders.confirmFirstSync(in: first)
    try await folders.confirmFirstSync(in: second)
    try FolderFixture.note("First", in: first)
    try FolderFixture.note("Held", in: first)
    _ = try await FolderFixture.sync(first)
    _ = try await FolderFixture.sync(second)
    let item = try #require(try await folders.status(of: first).files.first { $0.path == "Held.md" }?.itemId)

    // A delete held while the second folder is listed makes the first remember it.
    try FileManager.default.removeItem(at: first.appending(path: "First.md"))
    try await deletedPastTheGrace(first)
    try #require(try await folders.heldFiles(in: first).map(\.path) == ["First.md"])
    try #require(try await folders.trashHeld(in: first, paths: ["First.md"]).trashed == ["First.md"])

    // While the registry lists it, forgetting it changes nothing.
    let whileListed = try await folders.remembering(second)
    try #require(whileListed.listed && whileListed.folders.map(\.directory) == [first])
    let unchanged = try await folders.forget(whileListed)
    try #require(unchanged.listed && unchanged.forgotten.isEmpty)
    try #require(unchanged.notChanged.map(\.directory) == [first])

    try #require(try await folders.remove(second).removed)
    try FileManager.default.removeItem(at: second)
    try FileManager.default.removeItem(at: first.appending(path: "Held.md"))
    try await deletedPastTheGrace(first)
    let held = try #require(try await folders.heldFiles(in: first).first)
    try #require(held.path == "Held.md" && held.item == item)
    try #require(held.reason.contains(second.path(percentEncoded: false).dropLast()))

    let shown = try await folders.remembering(second)
    try #require(
        shown
            == Remembered(
                directory: second, listed: false,
                folders: [
                    RememberingFolder(
                        directory: first, folderId: folderId, store: try #require(shown.folders.first?.store),
                        held: [
                            WaitingHeldFile(
                                path: "Held.md", item: item, missingSince: held.missingSince, reason: held.reason)
                        ])
                ]))

    // Shown but not yet forgotten, the delete stays held.
    try #require(try await FolderFixture.sync(first).pass.scan.trashed.isEmpty)
    try #require(try await folders.heldFiles(in: first).map(\.path) == ["Held.md"])

    let done = try await folders.forget(shown)
    try #require(
        done
            == Forgotten(
                directory: second, listed: false,
                forgotten: [ForgottenIn(directory: first, folderId: folderId, released: ["Held.md"])]))
    try #require(try await folders.heldFiles(in: first).isEmpty)
    try #require(try await folders.list().map(\.directory) == [first])

    // No folder is left that could hold the file, so the next sync sends its delete.
    try #require(try await FolderFixture.sync(first).pass.scan.trashed == ["Held.md"])
    let server: Server = try #require(Live.server)
    let copy = try await WorkingCopy.open(store: Live.store(), server: server)
    _ = try await copy.hydrate(types: ["core.note"], tier: .library)
    let binned = try await copy.items.bin().items.map(\.id).contains(item)
    await copy.close()
    try #require(binned)
}

/// Syncs once the file is found missing and again past the rename grace, five seconds of the clock.
private func deletedPastTheGrace(_ directory: URL) async throws {
    _ = try await FolderFixture.sync(directory)
    try await Task.sleep(for: .seconds(6))
    _ = try await FolderFixture.sync(directory)
}
#endif
