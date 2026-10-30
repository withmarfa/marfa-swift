import Foundation
import MarfaCore
import Testing

@testable import Marfa

/// Times the reads an app makes of a large copy, over a store of `MARFA_READ_BENCH_ROWS` notes the core writes.
///
/// Run it in release, where the figures mean something:
/// `MARFA_READ_BENCH_ROWS=50000 swift test -c release -Xswiftc -enable-testing --filter ReadBench`.
@Suite(.serialized)
struct ReadBench {
    static let rows = ProcessInfo.processInfo.environment["MARFA_READ_BENCH_ROWS"].flatMap(Int.init)

    @Test(.enabled(if: rows != nil, "set MARFA_READ_BENCH_ROWS to the number of notes to time"))
    func timesAWholeListingAndTheBatchReads() async throws {
        let count = try #require(Self.rows)
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let body = String(repeating: "A line of a note's body, with [[a link]] in it. ", count: 6)
        let seeding = ContinuousClock.now
        for index in 0..<count {
            _ = try await copy.items.create(
                Draft(
                    type: "core.note",
                    properties: ["title": .string("Note \(index)"), "body": .string(body)]))
        }
        print("seeded \(count) notes in \(ContinuousClock.now - seeding)")

        let filters = ListFilters(allStates: true)
        let listed = try await copy.items.list(filters)
        #expect(listed.count == count)
        let list = try await Self.timed { _ = try await copy.items.list(filters) }

        let packed = Listing(items: listed.rows, completeness: listed.completeness)
        let decode = try await Self.timed { _ = try packed.answer }

        let ids = listed.prefix(1_000).map(\.id)
        let batch = try await Self.timed { _ = try await copy.items.get(ids) }
        let links = try await Self.timed { _ = try await copy.items.links(in: ids) }

        print(
            """
            read bench, \(count) notes (median of 5):
              items.list(allStates): \(list)
              of which reading the rows into Swift: \(decode)
              items.get of 1,000 ids: \(batch)
              items.links(in:) of 1,000 ids: \(links)
            """)
        await copy.close()
    }

    private static func timed(_ work: () async throws -> Void) async throws -> Duration {
        try await median {
            let start = ContinuousClock.now
            try await work()
            return ContinuousClock.now - start
        }
    }

    private static func median(_ work: () async throws -> Duration) async throws -> Duration {
        var times: [Duration] = []
        for _ in 0..<5 { times.append(try await work()) }
        return times.sorted()[2]
    }
}
