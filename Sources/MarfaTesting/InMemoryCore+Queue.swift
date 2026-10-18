import Foundation
import MarfaCore

extension InMemoryCore {
    func queue() throws -> [QueuedWrite] {
        state.withLock { state in state.entries.filter(\.inQueue).map(\.write) }
    }

    /// Offers each write that nothing holds back to the verdict chooser, in
    /// queue order.
    ///
    /// A write behind one the chooser left unanswered waits, and a write
    /// behind one that was not accepted is refused without being offered.
    func drain(stop: Stop?) throws -> DrainReport {
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
            case .behindRefusal(let waitedOn):
                let refusal = Refusal(
                    reason: "waited on \(waitedOn), which was not accepted", code: nil, message: nil, fields: [],
                    trashed: false, grant: nil)
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
        return report
    }

    func withdraw(id: String) throws -> Bool {
        try state.withLock { state in
            guard let at = state.at(id) else { throw Refuse.write(id) }
            switch state.entries[at].write.verdict {
            case .blocked(.ancestorUnavailable, _)?, .blocked(.conflictUnresolved, _)?:
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
        case behindRefusal(String)
        case ready(QueuedWrite, @Sendable (QueuedWrite) -> Verdict?)
    }

    func at(_ id: String) -> Int? {
        entries.firstIndex { $0.inQueue && $0.write.id == id }
    }

    private func answered(of id: String) -> Verdict?? {
        at(id).map { entries[$0].write.verdict }
    }

    func readiness(of id: String) -> Readiness {
        guard let index = at(id) else { return .waiting }
        let write = entries[index].write
        let ahead = write.dependsOn + [write.follows].compactMap { $0 }
        for waited in ahead {
            switch answered(of: waited) {
            case .some(.some(.refused)), .some(.some(.dead)), .some(.some(.blocked)): return .behindRefusal(waited)
            case .some(.none): return .waiting
            default: break
            }
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
        return DrainVerdict(
            id: id, kind: write.kind, itemId: write.itemId, edgeId: write.edgeId, verdict: verdict, refusals: 0,
            replayed: false)
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
