import Foundation
import MarfaCore
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1))) struct ViewWritesOffline {
    @Test func settingsWrittenAreReadBackUnchanged() throws {
        let read = try SavedView(
            MarfaCore.ViewRow(id: "view", version: 1, state: .active, settings: ViewsOffline.settings.core))
        let sent = read.settings.json
        #expect(try Self.sorted(sent) == Self.sorted(ViewsOffline.settings), "the same settings, under the same keys")
        let again = try SavedView(MarfaCore.ViewRow(id: "view", version: 1, state: .active, settings: sent.core))
        #expect(again.settings == read.settings)
    }

    private static func sorted(_ object: JSONObject) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(object), as: UTF8.self)
    }

    @Test func aViewWithNoSortOrGroupSendsNeither() {
        let settings = ViewSettings(title: "All")
        #expect(settings.json == ["title": "All", "query": [:]])
    }

    @Test func aChangeSendsOnlyTheSettingsItNames() {
        #expect(ViewSettingsChange().json == [:])
        #expect(ViewSettingsChange(title: "Renamed").json == ["title": "Renamed"])
        #expect(
            ViewSettingsChange(
                query: ViewQuery(types: ["core.task"]), sort: [ViewSort(by: "title", direction: .descending)],
                group: .set(ViewGrouping(by: "properties.status", hidden: ["done"]))
            ).json
                == [
                    "query": ["types": ["core.task"]],
                    "sort": [["by": "title", "direction": "desc"]],
                    "group": ["by": "properties.status", "hidden": ["done"]],
                ])
    }

    @Test func aChangeClearsASortWithAnEmptyListAndAGroupWithNull() {
        #expect(ViewSettingsChange(sort: []).json == ["sort": []])
        #expect(ViewSettingsChange(group: .clear).json == ["group": .null])
    }

    @Test func aCopyWithNoServerWritesNoViewAndQueuesNothing() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let id = "01a00000-0000-7000-8000-000000000001"
        let writes: [(String, () async throws -> Void)] = [
            (
                "createView",
                {
                    _ = try await copy.createView(
                        ViewSettings(title: "Offline"))
                }
            ),
            ("changeView", { _ = try await copy.changeView(id, ViewSettingsChange(title: "x"), baseVersion: 1) }),
            ("deleteView", { try await copy.deleteView(id) }),
        ]
        for (call, write) in writes {
            await #expect("\(call) is refused") {
                try await write()
            } throws: { error in
                if case .noServer = error as? Marfa.MarfaError { true } else { false }
            }
        }
        #expect(try await copy.queue.all().isEmpty)
        await copy.close()
    }

    @Test func aServerThatIsAwayFailsTheWriteAndQueuesNothing() async throws {
        let away = Server(url: URL(string: "http://127.0.0.1:9")!, key: "k")
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: away)
        let id = "01a00000-0000-7000-8000-000000000001"
        let writes: [(String, () async throws -> Void)] = [
            (
                "createView",
                {
                    _ = try await copy.createView(
                        ViewSettings(title: "Away"))
                }
            ),
            ("changeView", { _ = try await copy.changeView(id, ViewSettingsChange(title: "x"), baseVersion: 1) }),
            ("deleteView", { try await copy.deleteView(id) }),
        ]
        for (call, write) in writes {
            await #expect("\(call) is refused") {
                try await write()
            } throws: { error in
                if case .network = error as? Marfa.MarfaError { true } else { false }
            }
        }
        #expect(try await copy.queue.all().isEmpty)
        await copy.close()
    }
}

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveViewWrites {
        static func copy() async throws -> WorkingCopy {
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await copy.hydrate(types: ["core.task", "system.view"], tier: .all)
            return copy
        }

        static func settings(_ title: String = "Tasks \(UUID().uuidString.lowercased())") -> ViewSettings {
            ViewSettings(
                title: title, query: ViewQuery(types: ["core.task"], filter: "tags contains \"writes\""),
                sort: [ViewSort(by: "properties.title", direction: .ascending)],
                group: ViewGrouping(by: "properties.status", order: ["todo", "done"], hidden: ["later"]))
        }

        @Test func aViewIsMadeAndReadBackWithItsSettings() async throws {
            let copy = try await Self.copy()
            let heard = Heard(copy.changes())
            let settings = Self.settings()

            let made = try await copy.createView(settings)
            #expect(made.version == 1 && made.state == .active)
            #expect(made.settings == settings)
            #expect(try await copy.items.view(made.id) == made, "held at once")
            #expect(try await copy.items.views().map(\.id).contains(made.id))
            #expect(try await copy.items.groups(inView: made.id).isEmpty)

            let renamed = try await copy.changeView(made.id, ViewSettingsChange(title: "Renamed"), baseVersion: 1)
            #expect(renamed.version == 2 && renamed.settings.title == "Renamed")
            #expect(
                renamed.settings.sort == settings.sort && renamed.settings.group == settings.group,
                "a setting the change did not name stays")
            #expect(try await copy.items.view(made.id) == renamed)

            try await copy.deleteView(made.id)
            try await Task.sleep(for: .milliseconds(300))
            let created = Change(origin: .refreshed(.viewWritten), itemId: made.id, edgeId: nil)
            #expect(heard.all.filter { $0 == created }.count == 2, "each of the create and the change")
            #expect(
                heard.all.contains(Change(origin: .refreshed(.purged), itemId: made.id, edgeId: nil)),
                "and the delete")
            #expect(try await copy.queue.all().isEmpty, "nothing was queued")
            await copy.close()
        }

        @Test func aChangeReplacesTheSortAndTheGroupAndClearsEach() async throws {
            let copy = try await Self.copy()
            let made = try await copy.createView(Self.settings())

            let resorted = try await copy.changeView(
                made.id,
                ViewSettingsChange(
                    sort: [ViewSort(by: "created_at", direction: .descending)],
                    group: .set(ViewGrouping(by: "created_at", bucket: .month))),
                baseVersion: made.version)
            #expect(resorted.settings.sort == [ViewSort(by: "created_at", direction: .descending)])
            #expect(resorted.settings.group == ViewGrouping(by: "created_at", bucket: .month))
            #expect(resorted.settings.title == made.settings.title, "a setting the change did not name stays")

            let ungrouped = try await copy.changeView(
                made.id, ViewSettingsChange(group: .clear), baseVersion: resorted.version)
            #expect(ungrouped.settings.group == nil && ungrouped.settings.sort == resorted.settings.sort)
            #expect(try await copy.items.view(made.id) == ungrouped, "held at once")

            let unsorted = try await copy.changeView(
                made.id, ViewSettingsChange(sort: []), baseVersion: ungrouped.version)
            #expect(unsorted.settings.sort.isEmpty && unsorted.settings.group == nil)
            #expect(unsorted.settings.query == made.settings.query)
            try await copy.deleteView(made.id)
            await copy.close()
        }

        @Test func aRetriedCreateWithTheSameKeyMakesOneView() async throws {
            let copy = try await Self.copy()
            let key = "view-\(UUID().uuidString.lowercased())"
            let settings = Self.settings()
            let made = try await copy.createView(settings, idempotencyKey: key)
            let again = try await copy.createView(settings, idempotencyKey: key)
            #expect(again.id == made.id && again.version == made.version)
            let titled = try await copy.items.views().filter { $0.settings.title == settings.title }
            #expect(titled.map(\.id) == [made.id], "one view")

            let other = try await copy.createView(settings)
            #expect(other.id != made.id, "the witness: another key, another view")
            try await copy.deleteView(made.id)
            try await copy.deleteView(other.id)
            await copy.close()
        }

        @Test func aStaleChangeIsRefusedAndTheLocalViewIsUnchanged() async throws {
            let copy = try await Self.copy()
            let made = try await copy.createView(Self.settings("Before"))
            let renamed = try await copy.changeView(made.id, ViewSettingsChange(title: "Twice"), baseVersion: 1)
            let merged = try await copy.changeView(
                made.id, ViewSettingsChange(query: ViewQuery(types: ["core.task"])), baseVersion: 1)
            #expect(
                merged.version == 3 && merged.settings.title == "Twice",
                "a setting the other change did not touch is merged")

            await #expect {
                _ = try await copy.changeView(made.id, ViewSettingsChange(title: "Thrice"), baseVersion: 1)
            } throws: { error in
                if case .server(let status, let code, _) = error as? Marfa.MarfaError {
                    status == 409 && code == "version_conflict"
                } else {
                    false
                }
            }
            let kept = try #require(try await copy.items.view(made.id))
            #expect(kept == merged && kept.settings.title == renamed.settings.title, "the refused change left it")
            try await copy.deleteView(made.id)
            await copy.close()
        }

        @Test func aQueryTheServerRefusesIsRefusedWithItsCode() async throws {
            let copy = try await Self.copy()
            var settings = Self.settings()
            settings.query.filter = "title eq 1"
            await #expect {
                _ = try await copy.createView(settings)
            } throws: { error in
                if case .validation(let code, _) = error as? Marfa.MarfaError {
                    code == "validation_error"
                } else {
                    false
                }
            }
            let good = try await copy.createView(Self.settings())
            await #expect {
                _ = try await copy.changeView(
                    good.id, ViewSettingsChange(query: ViewQuery(filter: "title eq 1")), baseVersion: 1)
            } throws: { error in
                if case .validation(let code, _) = error as? Marfa.MarfaError {
                    code == "validation_error"
                } else {
                    false
                }
            }
            #expect(try await copy.items.view(good.id) == good, "the refused change left it")
            try await copy.deleteView(good.id)
            await copy.close()
        }

        @Test func aDeletedViewLeavesALiveQueryAndAnAbsentOneIsNotFound() async throws {
            let copy = try await Self.copy()
            let views = await LiveQuery(copy, reading: .views)
            let made = try await copy.createView(Self.settings())
            try await eventually("the new view shows") { await views.value.map(\.id).contains(made.id) }
            let groups = await LiveQuery(copy, reading: .groups(inView: made.id))
            try await eventually("its groups read") { await !groups.isLoading }
            #expect(await groups.error == nil)

            try await copy.deleteView(made.id)
            try await eventually("the deleted view leaves the query") { await !views.value.map(\.id).contains(made.id) }
            #expect(try await copy.items.view(made.id) == nil)

            await #expect {
                try await copy.deleteView(made.id)
            } throws: { error in
                if case .notFound(let code, _) = error as? Marfa.MarfaError { code == "item_not_found" } else { false }
            }
            #expect(try await copy.queue.all().isEmpty)
            await copy.close()
        }
    }
}
