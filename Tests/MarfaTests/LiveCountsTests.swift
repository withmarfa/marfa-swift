import Foundation
import Testing

@testable import Marfa

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveCounts {
        private func task(_ copy: WorkingCopy, _ title: String, status: String?) async throws -> String {
            var properties: JSONObject = ["title": .string(title)]
            if let status { properties["status"] = .string(status) }
            return try #require(
                try await copy.items.create(Draft(type: "core.task", properties: properties, tier: .library)).itemId)
        }

        @Test func aParentsChildrenAreCountedAlikeByTheCopyTheServerAndACopyOffline() async throws {
            let store = Live.store()
            let copy = try await WorkingCopy.open(store: store, server: Live.server)
            _ = try await copy.hydrate(types: ["core.task"], tier: .library, edgeTypes: ["parent-of"])

            let parent = try await task(copy, "parent \(UUID())", status: nil)
            let counted: [(String, String?)] = [
                ("planned", "not_started"), ("active", "in_progress"), ("done", "completed"),
                ("dropped", "canceled"), ("bare", nil),
            ]
            for (title, status) in counted {
                let child = try await task(copy, title, status: status)
                _ = try await copy.edges.create(from: parent, to: child, type: "parent-of")
            }
            let trashed = try await task(copy, "trashed", status: "not_started")
            let archived = try await task(copy, "archived", status: "completed")
            for child in [trashed, archived] {
                _ = try await copy.edges.create(from: parent, to: child, type: "parent-of")
            }
            let drained = try await copy.queue.drain()
            #expect(drained.verdicts.allSatisfy { $0.verdict == .accepted }, "\(drained.verdicts)")
            _ = try await copy.items.delete(trashed)
            _ = try await copy.items.transition(archived, to: .archived)
            let removed = try await copy.queue.drain()
            #expect(removed.verdicts.allSatisfy { $0.verdict == .accepted }, "\(removed.verdicts)")

            // Only the five active children count, one in each group and one in none.
            let expected = StatusGroupCounts(notStarted: 1, inProgress: 1, completed: 1, canceled: 1)
            let fromCopy = try #require(try await copy.counts(of: [parent], .backref(edgeType: "parent-of")).first)
            #expect(fromCopy.id == parent && fromCopy.total == 5 && fromCopy.statusGroups == expected, "\(fromCopy)")
            #expect(fromCopy.held, "the copy holds the edge type whole, so it answers itself")

            let server = try #require(Live.server)
            let fromServer = try #require(
                try await server.itemCounts(of: [parent], .backref(edgeType: "parent-of")).first)
            #expect(
                fromServer.total == fromCopy.total && fromServer.statusGroups == fromCopy.statusGroups, "\(fromServer)")
            #expect(!fromServer.held)

            // The same store with no server still answers, from what it holds.
            await copy.close()
            let offline = try await WorkingCopy.open(store: store, server: nil)
            let answered = try #require(try await offline.counts(of: [parent], .backref(edgeType: "parent-of")).first)
            #expect(answered.held && answered.total == fromServer.total, "\(answered)")
            #expect(answered.statusGroups == fromServer.statusGroups, "\(answered)")
            await offline.close()

            // A copy that does not hold the edge type asks its own server, and the numbers are the same.
            let asking = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await asking.hydrate(types: ["core.task"], tier: .library)
            let asked = try #require(try await asking.counts(of: [parent], .backref(edgeType: "parent-of")).first)
            #expect(!asked.held && asked.total == 5 && asked.statusGroups == expected, "\(asked)")
            await asking.close()
        }
    }
}
