import Foundation
import MarfaCore
import Synchronization
import Testing

@testable import Marfa

/// Supplies scripted answers for table holds and fills.
private final class HoldingCore: Core, @unchecked Sendable {
    private let answer = Mutex(MarfaCore.TableHold(type: "t", table: "steps", wasHeld: false, fill: nil))
    private let filled = Mutex(
        MarfaCore.TableFill(
            whole: 0, online: 0, unfilled: 0, pages: 0, rows: 0, failed: 0, failure: nil))

    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("a fake core has no handle") }

    func answer(wasHeld: Bool, fill: MarfaCore.TableFill?) {
        answer.withLock { $0 = MarfaCore.TableHold(type: "t", table: "steps", wasHeld: wasHeld, fill: fill) }
    }

    func answerFill(_ fill: MarfaCore.TableFill) { filled.withLock { $0 = fill } }

    override func heldHandle() -> MarfaCore.Handle { .writer }
    override func status() throws -> MarfaCore.Status { emptyStatus() }
    override func holdTable(typeId: String, table: String, stop: MarfaCore.Stop?) throws -> MarfaCore.TableHold {
        answer.withLock { $0 }
    }
    override func fillTables(stop: MarfaCore.Stop?) throws -> MarfaCore.TableFill { filled.withLock { $0 } }
}

private func fill(whole: UInt64 = 0, online: UInt64 = 0, rows: UInt64 = 0) -> MarfaCore.TableFill {
    MarfaCore.TableFill(
        whole: whole, online: online, unfilled: 0, pages: rows > 0 ? 1 : 0, rows: rows, failed: 0, failure: nil)
}

@Suite(.timeLimit(.minutes(1)))
struct TableHolds {
    @Test func aHoldTellsTheStreamsOnlyWhenTheChoiceIsNewOrItsFillChangedATable() async throws {
        let core = HoldingCore()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let heard = Heard(copy.changes())
        let tables = Marfa.Change(origin: .refreshed(.tables), itemId: nil, edgeId: nil)

        // The witness: a new choice is told.
        core.answer(wasHeld: false, fill: nil)
        _ = try await copy.tables.hold("steps", ofType: "t")
        try await eventually("a new choice is told") { heard.all == [tables] }

        // A choice already held with nothing left to fill is not, whether or not a fill ran.
        core.answer(wasHeld: true, fill: nil)
        _ = try await copy.tables.hold("steps", ofType: "t")
        core.answer(wasHeld: true, fill: fill())
        _ = try await copy.tables.hold("steps", ofType: "t")

        // A fill that read rows, left a table whole or found one past the cap is.
        for changed in [fill(rows: 3), fill(whole: 1), fill(online: 1)] {
            core.answer(wasHeld: true, fill: changed)
            _ = try await copy.tables.hold("steps", ofType: "t")
        }
        try await eventually("each fill that changed a table is told") { heard.all.count == 4 }
        #expect(heard.all == Array(repeating: tables, count: 4))
        heard.stop()
        await copy.close()
    }

    @Test func aFillTellsTheStreamsOnlyWhenItChangedATable() async throws {
        let core = HoldingCore()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let heard = Heard(copy.changes())
        let tables = Marfa.Change(origin: .refreshed(.tables), itemId: nil, edgeId: nil)

        core.answerFill(fill(online: 1))
        #expect(try await copy.tables.fill().online == 1)
        try await eventually("the table past the cap is told") { heard.all == [tables] }

        core.answerFill(fill())
        _ = try await copy.tables.fill()
        for changed in [fill(rows: 3), fill(whole: 1)] {
            core.answerFill(changed)
            _ = try await copy.tables.fill()
        }
        try await eventually("each fill that changed a table is told") { heard.all.count == 3 }
        #expect(heard.all == Array(repeating: tables, count: 3))
        heard.stop()
        await copy.close()
    }

    @Test func aTableTheFollowFilledIsToldToTheStreamsWithItsItem() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let heard = Heard(copy.changes())
        core.change(0, MarfaCore.Change.tableFilled(itemId: "item", table: "steps", cursor: "4"))
        let told = Marfa.Change(origin: .refreshed(.tables), itemId: "item", edgeId: nil)
        try await eventually("the filled table is told") { heard.all == [told] }
        try await bounded("close") { await copy.close() }
    }
}
