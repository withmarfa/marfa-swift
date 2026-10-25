import Foundation
import Testing

@testable import Marfa

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(1)))
    struct LiveCreateEdges {
        @Test func aCreateDrawnToACreateThatLandsOnAHeldRowEndsUpDrawnToTheHeldRow() async throws {
            let key = "landing-\(UUID())"
            let holder = try await Live.hydrated()
            _ = try await holder.items.create(
                Draft(type: "core.note", properties: ["body": "held"], tier: .feed, sourceId: key))
            let first = try await holder.queue.drain().verdicts
            #expect(first.map(\.verdict) == [.accepted], "\(first)")
            let held = try #require(first.first?.itemId)
            await holder.close()

            let copy = try await Live.hydrated()
            let lands = try #require(
                try await copy.items.create(
                    Draft(type: "core.note", properties: ["body": "again"], tier: .feed, sourceId: key)
                ).itemId)
            let drawn = try #require(
                try await copy.items.create(
                    Draft(
                        type: "core.note", properties: ["body": "drawn"], tier: .feed,
                        edges: ["references": [lands]])
                ).itemId)
            let report = try await copy.queue.drain()
            #expect(report.verdicts.allSatisfy { $0.verdict == .accepted }, "\(report.verdicts)")
            #expect(try await copy.edges.from(drawn).map(\.targetId) == [held])
            #expect(try await copy.items.get(lands) == nil)
            await copy.close()
        }
    }
}
