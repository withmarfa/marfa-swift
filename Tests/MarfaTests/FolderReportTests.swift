#if os(macOS)
import Foundation
import MarfaCore
import Testing

@testable import Marfa

/// A core pass with nothing in it, for a test to set what it looks at.
private func corePass(
    drain: MarfaCore.DrainReport = coreDrain(), flagged: [MarfaCore.FlaggedFile] = []
) -> MarfaCore.FolderPass {
    MarfaCore.FolderPass(
        settings: MarfaCore.SettingsFileOutcome(sent: false, written: false, flagged: nil, unwritten: nil),
        scan: MarfaCore.FolderScan(
            created: 0, updated: 0, renamed: 0, unchanged: 0, missing: 0, deleted: 0, skipped: 0, movedAway: 0,
            paused: 0, trashed: [], secrets: [], warnings: [], rootGone: nil),
        drain: drain, rebased: 0, gaveWay: 0,
        pull: MarfaCore.FolderPull(
            written: 0, rewritten: 0, moved: 0, unchanged: 0, skipped: 0, removed: 0, kept: 0, unwritten: 0,
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

@Test(arguments: ["unwritten", "outside", "unsuited", "absent", "retained"])
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
        verdict: .conflicted(siblingId: "copy-1", fields: ["body"]), refusals: 0, replayed: false)
    let placement = MarfaCore.DrainVerdict(
        id: "w2", kind: .createEdge, itemId: "item-2", edgeId: "edge-2", verdict: .accepted, refusals: 0,
        replayed: false)
    let pass = Marfa.FolderPass(corePass(drain: coreDrain(answered: 2, verdicts: [edit, placement])))
    #expect(pass.drain.answered == 2)
    #expect(pass.drain.verdicts.map(\.id) == ["w1", "w2"])
    guard case .conflicted(let copy, let fields)? = pass.drain.verdicts.first?.verdict else {
        Issue.record("the conflicted edit was not carried: \(pass.drain.verdicts)")
        return
    }
    #expect(copy == "copy-1")
    #expect(fields == ["body"])
    #expect(pass.drain.verdicts.first?.itemId == "item-1")
}
#endif
