#if DEBUG
import Foundation
import Marfa
import MarfaTesting
import Testing

/// The tables of a copy that never reached a server, and so holds none.
@Suite(.timeLimit(.minutes(1)))
struct TablesOffline {
    static let item = "019a0000-0000-7000-8000-000000000001"
    static let batch = "019a0000-0000-7000-8000-0000000000d4"

    static func itemNotFound(_ error: any Error) -> Bool {
        if case .notFound("item_not_found", _, _)? = error as? MarfaError { true } else { false }
    }

    @Test(arguments: CopyKind.allCases)
    func aCopyThatHoldsNoTableListsNoneAndLetsGoOfNone(kind: CopyKind) async throws {
        let copy = try await kind.open()
        #expect(try await copy.tables.held() == HeldTables())
        #expect(try await copy.tables.letGo("steps", ofType: "app.test.steps") == false)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aWriteToAnItemTheCopyDoesNotHoldIsRefusedAndNotQueued(kind: CopyKind) async throws {
        let copy = try await kind.open()
        await #expect {
            _ = try await copy.tables.write([.put(values: ["note": "x"])], to: "steps", of: Self.item)
        } throws: { Self.itemNotFound($0) }
        await #expect {
            _ = try await copy.tables.undo(batch: Self.batch, in: "steps", of: Self.item)
        } throws: { Self.itemNotFound($0) }
        #expect(try await copy.queue.all().isEmpty)
        await copy.close()
    }

    @Test func theFakeThrowsUnsupportedForEveryTableCallItCannotMatch() async throws {
        let fake = try await CopyKind.makeFake()
        let id = try #require(
            try await fake.copy.items.create(Draft(type: "core.note", properties: ["title": "held"])).itemId)
        let tables = fake.copy.tables
        func refused(_ call: String, _ work: () async throws -> Void) async {
            await #expect {
                try await work()
            } throws: { error in
                (error as? FakeCopyError) == .unsupported(call: call)
            }
        }
        await refused("tables.hold") { _ = try await tables.hold("steps", ofType: "core.note") }
        await refused("tables.fill") { _ = try await tables.fill() }
        await refused("tables.rows") { _ = try await tables.rows(of: id, in: "steps") }
        await refused("tables.row") { _ = try await tables.row(Self.item, of: id, in: "steps") }
        await refused("tables.totals") { _ = try await tables.totals(of: id, in: "steps") }
        await refused("tables.write") { _ = try await tables.write([.delete(id: Self.item)], to: "steps", of: id) }
        await refused("tables.undo") { _ = try await tables.undo(batch: Self.batch, in: "steps", of: id) }
        let queued = try await fake.copy.queue.all()
        #expect(queued.map(\.kind) == [.createItem], "a refused table call queued a write: \(queued)")
        await fake.copy.close()
    }
}
#endif
