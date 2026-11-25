#if os(macOS)
import Foundation
import MarfaCore
import Testing

@testable import Marfa

/// A core pass with nothing in it, for a test to set what it looks at.
private func corePass(
    drain: MarfaCore.DrainReport = coreDrain(), flagged: [MarfaCore.FlaggedFile] = [], removed: UInt64 = 0,
    purged: UInt64 = 0, unchanged: UInt64 = 0, waiting: UInt64 = 0, busy: UInt64 = 0
) -> MarfaCore.FolderPass {
    MarfaCore.FolderPass(
        settings: MarfaCore.SettingsFileOutcome(sent: false, written: false, flagged: nil, unwritten: nil),
        scan: MarfaCore.FolderScan(
            created: 0, updated: 0, renamed: 0, unchanged: unchanged, waiting: waiting, missing: 0, deleted: 0,
            skipped: 0, movedAway: 0,
            paused: 0, pausedAdditions: 0, heldOutside: 0, trashed: [], secrets: [], warnings: [], rootGone: nil,
            lookupRefused: nil),
        drain: drain, rebased: 0, gaveWay: 0,
        pull: MarfaCore.FolderPull(
            written: 0, rewritten: 0, moved: 0, unchanged: 0, skipped: 0, removed: removed, purged: purged, kept: 0,
            unwritten: 0, busy: busy,
            absent: 0, unplaced: 0, unmatched: 0, paused: 0, rootGone: nil),
        flagged: flagged)
}

private func coreDrain(
    answered: UInt64 = 0, verdicts: [MarfaCore.DrainVerdict] = []
) -> MarfaCore.DrainReport {
    MarfaCore.DrainReport(
        answered: answered, held: 0, undelivered: 0, unsent: 0, unmade: 0, unavailable: nil, verdicts: verdicts,
        stopped: nil, unclaimedSources: [], retryAfterSeconds: nil)
}

@Test func aPassSaysHowManyOfTheFilesItRemovedWereOfPurgedItems() {
    let pass = Marfa.FolderPass(corePass(removed: 5, purged: 2))
    #expect(pass.pull?.removed == 5)
    #expect(pass.pull?.purged == 2, "of the removed, not on top of them")
    #expect(Marfa.FolderPass(corePass()).pull?.purged == 0)
}

@Test func aPassSaysHowManyFilesItLeftBecauseAProgramHoldsThemOpen() {
    #expect(Marfa.FolderPass(corePass(busy: 3)).pull?.busy == 3)
    #expect(Marfa.FolderPass(corePass()).pull?.busy == 0)
}

@Test func aPassCountsFilesWithAWriteWaitingApartFromUnchangedOnes() {
    let scan = Marfa.FolderPass(corePass(unchanged: 3, waiting: 2)).scan
    #expect(scan.unchanged == 3, "waiting files are not unchanged")
    #expect(scan.waiting == 2)
    #expect(Marfa.FolderPass(corePass()).scan.waiting == 0)
}

@Test(arguments: ["unwritten", "outside", "unsuited", "absent"])
func aFlaggedFileNamesTheItemAPullHeldBack(flag: String) {
    let item = "01a00000-0000-7000-8000-000000000042"
    let flagged = Marfa.FlaggedFile(
        MarfaCore.FlaggedFile(path: "Notes/id_rsa", flag: flag, reason: "its name is a secret's", item: item))
    #expect(flagged.item == item)
    #expect(flagged.path == "Notes/id_rsa")
    #expect(flagged.flag == flag)
    #expect(flagged.reason == "its name is a secret's")
}

@Test func aFlaggedFileTheScanHeldNamesNoItem() {
    let flagged = Marfa.FlaggedFile(
        MarfaCore.FlaggedFile(path: "big.bin", flag: "unreadable", reason: "too large", item: nil))
    #expect(flagged.item == nil)
}

@Test func aPassNamesEachItemItsPullHeldBackEvenWhereTwoAreAtOnePath() {
    let first = "01a00000-0000-7000-8000-000000000051"
    let second = "01a00000-0000-7000-8000-000000000052"
    let pass = Marfa.FolderPass(
        corePass(
            flagged: [
                MarfaCore.FlaggedFile(path: "id_rsa", flag: "outside", reason: "a secret's name", item: first),
                MarfaCore.FlaggedFile(path: "id_rsa", flag: "outside", reason: "a secret's name", item: second),
                MarfaCore.FlaggedFile(path: "big.bin", flag: "unreadable", reason: "too large", item: nil),
            ]))
    #expect(pass.flagged.map(\.item) == [first, second, nil])
    #expect(pass.flagged.map(\.path) == ["id_rsa", "id_rsa", "big.bin"])
}

@Test func aPassCarriesAConflictedEditAndThePlacementsASecondDrainSent() {
    let edit = MarfaCore.DrainVerdict(
        id: "w1", kind: .updateItem, itemId: "item-1", edgeId: nil,
        verdict: .conflicted(siblingId: "copy-1", fields: ["body"], conflicts: []), refusals: 0, replayed: false)
    let placement = MarfaCore.DrainVerdict(
        id: "w2", kind: .createEdge, itemId: "item-2", edgeId: "edge-2", verdict: .accepted, refusals: 0,
        replayed: false)
    let pass = Marfa.FolderPass(corePass(drain: coreDrain(answered: 2, verdicts: [edit, placement])))
    #expect(pass.drain.answered == 2)
    #expect(pass.drain.verdicts.map(\.id) == ["w1", "w2"])
    guard case .conflicted(let copy, let fields, _)? = pass.drain.verdicts.first?.verdict else {
        Issue.record("the conflicted edit was not carried: \(pass.drain.verdicts)")
        return
    }
    #expect(copy == "copy-1")
    #expect(fields == ["body"])
    #expect(pass.drain.verdicts.first?.itemId == "item-1")
}

@Test(arguments: [
    (MarfaCore.StorageCause.iCloudDrive, Marfa.StorageCause.iCloudDrive),
    (.cloudService, .cloudService),
    (.cloudSynced, .cloudSynced),
    (.networkFileSystem(kind: "smbfs"), .networkFileSystem(kind: "smbfs")),
])
func aFolderInSyncedOrNetworkStorageIsAddedWithTheCause(core: MarfaCore.StorageCause, expected: Marfa.StorageCause) {
    let added = Marfa.AddedFolder(MarfaCore.AddedFolder(dir: "/Notes", folder: "f", storage: core, gitTracked: false))
    #expect(added.storage == expected)
    #expect(added.folderId == "f")
    #expect(added.directory == URL(filePath: "/Notes", directoryHint: .isDirectory))
    let watching = Marfa.FolderEvent(MarfaCore.FolderEvent.watching(dir: "/Notes", storage: core))
    #expect(watching == .watching(URL(filePath: "/Notes", directoryHint: .isDirectory), storage: expected))
}

@Test(arguments: [true, false])
func aListedFolderSaysWhetherItsSyncIsPaused(paused: Bool) {
    let store = paused ? "store-1" : nil
    let listed = Marfa.ListedFolder(MarfaCore.ListedFolder(dir: "/Notes", folder: "f", paused: paused, store: store))
    #expect(listed.storeId == store)
    let added = Marfa.AddedFolder(MarfaCore.AddedFolder(dir: "/Notes", folder: "f", storage: nil, gitTracked: paused))
    #expect(added.gitTracked == paused)
    #expect(listed.syncPaused == paused)
    #expect(listed.folderId == "f")
}

@Test(arguments: [("removing", Marfa.FileState.removing), ("unsure", .unsure), ("future", .held)])
func aHeldFileKeepsItsFlagAndReason(flag: String, expected: Marfa.FileState) {
    let file = Marfa.FileStatus(
        MarfaCore.FileStatus(
            path: "a.md", itemId: "a", state: .held, waits: [], flag: flag, reason: "why", warning: nil))
    #expect(file.state == expected && file.reason == "why" && file.flag == flag)
}

@Test func unmatchedAndKeptResultsCarryEveryBindingField() {
    let removal = Marfa.UnmatchedRemoved(
        MarfaCore.UnmatchedRemoved(
            removed: [.init(path: "a", itemId: "1")], kept: [.init(path: "b", itemId: nil, reason: "edited")], ended: 2)
    )
    #expect(
        removal
            == .init(
                removed: [.init(path: "a", itemId: "1")], kept: [.init(path: "b", itemId: nil, reason: "edited")],
                ended: 2))
    let records = MarfaCore.KeptWriters.allCases.enumerated().map { index, writer in
        MarfaCore.KeptFile(
            path: "aside-\(index)", from: "old", writers: writer, until: index == 1 ? "2026-12-01" : nil, reason: "busy"
        )
    }
    let discard = Marfa.KeptDiscarded(.init(discarded: ["gone"], putBack: ["edited"], kept: records))
    #expect(discard.discarded == ["gone"] && discard.putBack == ["edited"])
    #expect(discard.kept.map(\.writers) == [.open, .unknown, .notLooked])
    #expect(discard.kept.map(\.path) == ["aside-0", "aside-1", "aside-2"])
    #expect(discard.kept.map(\.until) == [nil, "2026-12-01", nil])
    #expect(discard.kept.allSatisfy { $0.from == "old" && $0.reason == "busy" })
}

@Test(arguments: [(true, UInt64(3)), (false, UInt64(0)), (false, UInt64(7))])
func aFolderStatusSaysWhetherItsSyncIsPausedAndHowManyDirectoriesAreUnwatched(paused: Bool, unwatched: UInt64) {
    let status = Marfa.FolderStatus(
        MarfaCore.FolderStatus(
            directories: [], files: [],
            paused: MarfaCore.FolderPaused(disk: 0, pull: 0, additions: 0, outsideQuery: 0), firstSync: nil,
            syncPaused: paused, unwatched: unwatched))
    #expect(status.syncPaused == paused)
    #expect(status.unwatched == unwatched)
    #expect(!status.paused.isPaused, "a paused sync is not a paused removal")
}

@Test func aFolderStatusNamesTheDirectoriesItFlagged() {
    let status = Marfa.FolderStatus(
        MarfaCore.FolderStatus(
            directories: [
                MarfaCore.FlaggedFile(path: "Notes/.ssh", flag: "outside", reason: "a secret's name", item: nil),
                MarfaCore.FlaggedFile(path: "Notes/big", flag: "unreadable", reason: "cannot be read", item: "item-1"),
            ],
            files: [], paused: MarfaCore.FolderPaused(disk: 0, pull: 0, additions: 0, outsideQuery: 0), firstSync: nil,
            syncPaused: false, unwatched: 0))
    #expect(status.directories.map(\.path) == ["Notes/.ssh", "Notes/big"])
    #expect(status.directories.map(\.flag) == ["outside", "unreadable"])
    #expect(status.directories.map(\.reason) == ["a secret's name", "cannot be read"])
    #expect(status.directories.map(\.item) == [nil, "item-1"])
}

@Test func aFolderStatusWithNoFlaggedDirectoriesHasNone() {
    let status = Marfa.FolderStatus(
        MarfaCore.FolderStatus(
            directories: [], files: [], paused: MarfaCore.FolderPaused(disk: 0, pull: 0, additions: 0, outsideQuery: 0),
            firstSync: nil, syncPaused: false, unwatched: 0))
    #expect(status.directories.isEmpty)
    #expect(Marfa.FolderStatus(files: []).directories.isEmpty)
}

@Test func aWatchTellsWhenTheFolderSyncWasPaused() {
    #expect(Marfa.FolderEvent(MarfaCore.FolderEvent.paused) == .paused)
}

@Test func aFolderInPlainStorageIsAddedWithNoCause() {
    let added = Marfa.AddedFolder(MarfaCore.AddedFolder(dir: "/Notes", folder: "f", storage: nil, gitTracked: false))
    #expect(added.storage == nil)
    #expect(
        Marfa.FolderEvent(MarfaCore.FolderEvent.watching(dir: "/Notes", storage: nil))
            == .watching(URL(filePath: "/Notes", directoryHint: .isDirectory), storage: nil))
}

@Test func eachCauseHasOnePlainWarningThatNamesIt() {
    #expect(StorageCause.iCloudDrive.warning.hasPrefix("This folder is in iCloud Drive."))
    #expect(StorageCause.cloudService.warning.hasPrefix("This folder is in a cloud service."))
    #expect(StorageCause.cloudSynced.warning.hasPrefix("This folder is in iCloud Drive or another cloud service."))
    let network = StorageCause.networkFileSystem(kind: "smbfs").warning
    #expect(network.hasPrefix("This folder is on a network file system (smbfs)."))
    #expect(network.contains("another computer"))
    #expect(StorageCause.cloudSynced.location == "iCloud Drive or another cloud service")
}
#endif
