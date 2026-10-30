#if DEBUG
import Foundation
import Marfa
import MarfaTesting
import Testing

/// What one drain does with a queue as long as a connector import or a bulk
/// command leaves.
///
/// A real copy with no server answers no write, so it holds the same queue and
/// reports no verdict; only the fake answers here, and the real copy runs where
/// `MARFA_API_URL` and `MARFA_API_KEY` name a server.
@Suite(.timeLimit(.minutes(5)))
struct BulkDrain {
    static let count = 5_000

    @Test(arguments: CopyKind.allCases)
    func oneDrainAnswersEveryWriteOfALongQueue(kind: CopyKind) async throws {
        let copy: WorkingCopy
        switch kind {
        case .real:
            guard let server = LiveServer.server else {
                try Test.cancel("set MARFA_API_URL and MARFA_API_KEY to run against a server")
                return
            }
            copy = try await WorkingCopy.open(store: temporaryStore(), server: server)
            _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
        case .fake:
            copy = try await kind.open()
        }
        var queued: [String] = []
        queued.reserveCapacity(Self.count)
        for number in 0..<Self.count {
            let write = try await copy.items.create(
                Draft(type: "core.note", properties: ["title": .string("n \(number)"), "body": "b"], tier: .feed))
            queued.append(write.id)
        }

        let report = try await copy.queue.drain()

        #expect(report.verdicts.map(\.id) == queued)
        #expect(report.verdicts.allSatisfy { $0.verdict == .accepted })
        #expect(report.answered == UInt64(Self.count))
        #expect(try await copy.queue.all().allSatisfy { $0.verdict == .accepted })
        await copy.close()
    }
}
#endif
