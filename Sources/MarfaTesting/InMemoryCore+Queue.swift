#if DEBUG
import Foundation
import MarfaCore

extension InMemoryCore {
    func queue() throws -> [QueuedWrite] {
        state.withLock { state in state.entries.filter(\.inQueue).map(\.write) }
    }

    /// Offers each write that nothing holds back to the verdict chooser, in
    /// queue order, one drain at a time.
    ///
    /// A write behind one still unanswered waits, and one that depends on a
    /// refused or dead write is refused without being offered.
    func drain(stop: Stop?) throws -> DrainReport {
        draining.lock()
        defer { draining.unlock() }
        var report = DrainReport(
            answered: 0, held: 0, undelivered: 0, unsent: 0, unmade: 0, unavailable: nil, verdicts: [],
            stopped: nil, unclaimedSources: [], retryAfterSeconds: nil)
        let pending = state.withLock { state in
            state.entries.filter { $0.inQueue && $0.write.verdict == nil }.map(\.write.id)
        }
        for id in pending {
            switch state.withLock({ $0.readiness(of: id) }) {
            case .waiting:
                state.withLock { $0.setWaiting(id) }
                report.held += 1
            case .refused(let reason):
                let refusal = Refusal(
                    reason: reason, code: nil, message: nil, fields: [], trashed: false, grant: nil)
                report.verdicts.append(state.withLock { $0.answer(id, .refused(refusal: refusal)) })
                report.unsent += 1
            case .ready(let write, let choose):
                if let verdict = choose(write) {
                    report.verdicts.append(state.withLock { $0.answer(id, verdict) })
                    report.answered += 1
                } else {
                    report.undelivered += 1
                }
            }
        }
        state.withLock { $0.replay() }
        return report
    }

    func withdraw(id: String) throws -> Bool {
        try state.withLock { state in
            guard let at = state.at(id) else { throw Refuse.write(id) }
            switch state.entries[at].write.verdict {
            case .blocked(.ancestorUnavailable, _)?, .blocked(.conflictUnresolved, _)?, .blocked(.failingAlone, _)?:
                state.entries[at].inQueue = false
                for other in state.entries.indices
                where state.entries[other].inQueue && state.entries[other].write.verdict == nil
                    && state.entries[other].write.dependsOn.contains(id)
                {
                    let waited = state.entries[other].write.id
                    let refusal = Refusal(
                        reason: "waited on \(id), which was withdrawn", code: nil, message: nil, fields: [],
                        trashed: false, grant: nil)
                    _ = state.answer(waited, .refused(refusal: refusal))
                }
                state.entries[at].withdrawn = true
                state.replay()
                return true
            default:
                return false
            }
        }
    }

    func discard(id: String) throws -> Bool {
        try state.withLock { state in
            guard let at = state.at(id) else { throw Refuse.write(id) }
            guard case .refused? = state.entries[at].write.verdict, !state.isWaitedOn(id) else { return false }
            state.entries[at].inQueue = false
            return true
        }
    }

    func forgetAnswered() throws -> UInt64 {
        state.withLock { $0.forget(only: nil) }
    }

    func forgetAnsweredIds(ids: [String]) throws -> UInt64 {
        state.withLock { $0.forget(only: Set(ids)) }
    }
}

extension InMemoryCore.State {
    enum Readiness {
        case waiting
        case refused(String)
        case ready(QueuedWrite, @Sendable (QueuedWrite) -> Verdict?)
    }

    func at(_ id: String) -> Int? {
        entries.firstIndex { $0.inQueue && $0.write.id == id }
    }

    private func answered(of id: String) -> Verdict?? {
        at(id).map { entries[$0].write.verdict }
    }

    /// Whether a write goes, waits or is refused unsent, in the order the core
    /// asks: the write ahead of it first, then what it depends on, then its
    /// own version.
    func readiness(of id: String) -> Readiness {
        guard let index = at(id) else { return .waiting }
        let write = entries[index].write
        if let ahead = write.follows, answered(of: ahead) == .some(.none) { return .waiting }
        for waited in write.dependsOn {
            switch answered(of: waited) {
            case .none, .some(.none), .some(.blocked?): return .waiting
            case .some(.refused?), .some(.dead?):
                let kind = entries[at(waited) ?? index].write.kind
                let verdict: String =
                    if case .dead? = entries[at(waited) ?? index].write.verdict { "dead" } else { "refused" }
                return .refused("the \(kind.name) it waits for was \(verdict)")
            default: break
            }
        }
        if write.kind == .deleteItem, (write.baseVersion ?? 0) <= 0 {
            return .refused("the delete has no confirmed server version to remove; read the item before deleting it")
        }
        return .ready(write, verdict)
    }

    mutating func setWaiting(_ id: String) {
        if let index = at(id) { entries[index].write.waiting = true }
    }

    mutating func answer(_ id: String, _ verdict: Verdict) -> DrainVerdict {
        guard let index = at(id) else {
            return DrainVerdict(
                id: id, kind: .createItem, itemId: nil, edgeId: nil, verdict: verdict, refusals: 0, replayed: false)
        }
        entries[index].write.verdict = verdict
        entries[index].write.waiting = false
        entries[index].write.answeredAt = Minted.now()
        let write = entries[index].write
        if write.kind == .createItem {
            switch verdict {
            case .accepted, .merged: rebaseDeletes(behind: write)
            default: break
            }
        }
        return DrainVerdict(
            id: id, kind: write.kind, itemId: write.itemId, edgeId: write.edgeId, verdict: verdict, refusals: 0,
            replayed: false)
    }

    /// The core moves a delete queued at version 0 behind its own create to
    /// version 1 when that create is taken, so the delete goes on the version
    /// the create made.
    private mutating func rebaseDeletes(behind create: QueuedWrite) {
        for at in entries.indices {
            let entry = entries[at].write
            guard entries[at].inQueue, entry.verdict == nil, entry.kind == .deleteItem,
                entry.itemId == create.itemId, entry.baseVersion == 0
            else { continue }
            entries[at].write.baseVersion = 1
            for member in entries[at].write.body.members.indices
            where entries[at].write.body.members[member].key == "version" {
                entries[at].write.body.members[member].value = .integer(1)
            }
        }
    }

    func isWaitedOn(_ id: String) -> Bool {
        entries.contains {
            $0.inQueue && $0.write.verdict == nil && ($0.write.dependsOn.contains(id) || $0.write.follows == id)
        }
    }

    /// Clears answered writes, keeping those a waiting write needs, the ones
    /// that are blocked or dead, and a refused write that carries content.
    mutating func forget(only ids: Set<String>?) -> UInt64 {
        var cleared: UInt64 = 0
        for index in entries.indices where entries[index].inQueue {
            let write = entries[index].write
            if let ids, !ids.contains(write.id) { continue }
            let clearable: Bool =
                switch write.verdict {
                case .accepted?, .merged?, .conflicted?: true
                case .refused?: write.body.members.isEmpty
                case .blocked?, .dead?, nil: false
                }
            if clearable, !isWaitedOn(write.id) {
                entries[index].inQueue = false
                cleared += 1
            }
        }
        return cleared
    }
}
#endif
