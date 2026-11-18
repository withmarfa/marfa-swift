import Foundation
import MarfaCore
import Synchronization
import Testing

@testable import Marfa

/// A core whose answer to a hold a test scripts.
private final class HoldingCore: Core, @unchecked Sendable {
    private let answer = Mutex(MarfaCore.TableHold(type: "t", table: "steps", wasHeld: false, fill: nil))

    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("a fake core has no handle") }

    func answer(wasHeld: Bool, fill: MarfaCore.TableFill?) {
        answer.withLock { $0 = MarfaCore.TableHold(type: "t", table: "steps", wasHeld: wasHeld, fill: fill) }
    }

    override func heldHandle() -> MarfaCore.Handle { .writer }
    override func status() throws -> MarfaCore.Status { emptyStatus() }
    override func holdTable(typeId: String, table: String, stop: MarfaCore.Stop?) throws -> MarfaCore.TableHold {
        answer.withLock { $0 }
    }
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
