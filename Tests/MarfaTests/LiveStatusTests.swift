import Foundation
import Testing

@testable import Marfa

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveStatus {
        static func tag() -> String {
            "status\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
        }

        /// One task in each group, and one in no group, under a tag of their own.
        static func tasks(in copy: WorkingCopy, tag: String) async throws -> [String: String] {
            var ids: [String: String] = [:]
            for (title, status) in [
                ("planned", "not_started"), ("active", "in_progress"), ("done", "completed"),
                ("dropped", "canceled"), ("bare", nil),
            ] as [(String, String?)] {
                var properties: JSONObject = ["title": .string(title)]
                if let status { properties["status"] = .string(status) }
                ids[title] = try #require(
                    try await copy.items.create(
                        Draft(type: "core.task", properties: properties, tags: [tag], tier: .library)
                    )
                    .itemId)
            }
            _ = try await copy.queue.drain()
            return ids
        }

        @Test func aTypeReadFromTheServerGivesItsStatusWordsAndGroups() async throws {
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await copy.hydrate(types: ["core.task", "core.event"], tier: .all)
            let task = try await copy.catalog.itemType("core.task")
            #expect(task.statusField == "status")
            #expect(
                task.statusWords == StatusGroup.allCases.map { StatusWord(value: $0.rawValue, group: $0) },
                "the four words are the group names")
            let event = try await copy.catalog.itemType("core.event")
            #expect(event.statusField == nil, "an event's status is fixed to three values and has no groups")
            #expect(event.fields.first { $0.name == "status" }?.type == "enum")
            await copy.close()
        }

        @Test func aListFiltersByStatusGroupAndTheServerAgrees() async throws {
            let tag = Self.tag()
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await copy.hydrate(types: ["core.task"], tier: .all)
            let ids = try await Self.tasks(in: copy, tag: tag)
            let mine = "tags contains \"\(tag)\""

            let notDone = try await copy.items.list(
                ListFilters(
                    filter: "\(mine) AND status_group neq \"completed\" AND status_group neq \"canceled\""))
            #expect(
                Set(notDone.map(\.id)) == Set([ids["planned"], ids["active"]].compactMap { $0 }),
                "a task that holds no status is in no group, so neq does not select it")

            let ungrouped = try await copy.items.list(ListFilters(filter: "\(mine) AND status_group not_exists"))
            #expect(ungrouped.map(\.id) == [ids["bare"]].compactMap { $0 })
            let grouped = try await copy.items.list(ListFilters(filter: "\(mine) AND status_group exists"))
            #expect(grouped.count == 4)

            let finished = try await copy.items.list(ListFilters(filter: "\(mine) AND status_group eq \"completed\""))
            #expect(finished.map(\.id) == [ids["done"]].compactMap { $0 })

            let groups = try await copy.catalog.statusGroups(
                of: Array(try await copy.items.list(ListFilters(filter: mine))))
            #expect(groups.compactMap { $0 }.count == 4 && groups.filter { $0 == nil }.count == 1)

            for refusal in ["status_group eq \"todo\"", "status_group contains \"completed\""] {
                await #expect {
                    _ = try await copy.items.list(ListFilters(filter: "\(mine) AND \(refusal)"))
                } throws: { error in
                    if case .validation("validation_error", _)? = error as? MarfaError { true } else { false }
                }
            }
            await copy.close()
        }

        @Test func aViewFiltersByStatusGroup() async throws {
            let tag = Self.tag()
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await copy.hydrate(types: ["core.task", "system.view"], tier: .all)
            let ids = try await Self.tasks(in: copy, tag: tag)
            let view = try await Live.writeView([
                "title": .string("Not done \(tag)"),
                "query": [
                    "types": ["core.task"],
                    "filter": .string(
                        "tags contains \"\(tag)\" AND status_group neq \"completed\" AND status_group neq \"canceled\""),
                ],
                "sort": [["by": "properties.title", "direction": "asc"]],
            ])
            _ = try await copy.hydrate(types: ["core.task", "system.view"], tier: .all)
            let listed = try await copy.items.list(inView: view)
            #expect(listed.map(\.title) == ["active", "planned"])
            #expect(Set(listed.map(\.id)) == Set([ids["planned"], ids["active"]].compactMap { $0 }))
            try await Live.deleteView(view)
            await copy.close()
        }
    }
}
