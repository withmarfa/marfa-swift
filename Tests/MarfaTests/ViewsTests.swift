import Foundation
import MarfaCore
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1))) struct ViewsOffline {
    static let settings: JSONObject = [
        "title": "Everything",
        "query": [
            "types": ["core.task"], "tier": "feed", "state": ["archived"], "filter": "tags contains \"x\"",
            "beneath": "parent",
        ],
        "layouts": [
            ["id": "rows", "kind": "list"],
            [
                "id": "grid", "kind": "table", "title": "Grid", "shown": ["title", "properties.status"],
                "sort": [
                    ["by": "properties.status", "direction": "desc"], ["by": "created_at", "direction": "asc"],
                ],
            ],
            [
                "id": "board", "kind": "board",
                "group": ["by": "properties.status", "order": ["todo", nil, 3], "hidden": [false]],
            ],
            ["id": "cards", "kind": "gallery", "image": "properties.cover"],
            ["id": "days", "kind": "calendar", "date": "properties.due", "end": "occurred_at"],
            ["id": "spans", "kind": "timeline", "start": "created_at", "end": "properties.due"],
            [
                "id": "chart", "kind": "chart", "x": "tags", "y": ["sum": "properties.hours"],
                "group": ["by": "created_at", "bucket": "week"],
            ],
            ["id": "count", "kind": "chart", "y": "count"],
            ["id": "places", "kind": "map", "location": "properties.where"],
        ],
    ]

    private func read(_ settings: JSONObject = Self.settings) throws -> SavedView {
        try SavedView(
            MarfaCore.ViewRow(id: "view", version: 4, state: .active, settings: settings))
    }

    @Test func aViewKeepsEveryLayoutKindWithItsOptions() throws {
        let view = try read()
        #expect(view.id == "view" && view.version == 4 && view.state == .active)
        #expect(view.settings.title == "Everything")
        #expect(
            view.settings.query
                == ViewQuery(
                    types: ["core.task"], tier: .feed, states: [.archived], filter: "tags contains \"x\"",
                    beneath: "parent"))
        let layouts = view.settings.layouts
        #expect(layouts.map(\.id) == ["rows", "grid", "board", "cards", "days", "spans", "chart", "count", "places"])
        #expect(
            layouts.map(\.kind) == [
                .list, .table, .board, .gallery(image: "properties.cover"),
                .calendar(date: "properties.due", end: "occurred_at"),
                .timeline(start: "created_at", end: "properties.due"),
                .chart(x: "tags", y: .sum("properties.hours")), .chart(x: nil, y: .count),
                .map(location: "properties.where"),
            ])
        #expect(layouts[1].title == "Grid" && layouts[1].shown == ["title", "properties.status"])
        #expect(
            layouts[1].sort == [
                ViewSort(by: "properties.status", direction: .descending),
                ViewSort(by: "created_at", direction: .ascending),
            ], "the keys in their declared order")
        #expect(
            layouts[2].group
                == ViewGrouping(by: "properties.status", order: ["todo", nil, 3], hidden: [false]))
        #expect(layouts[6].group == ViewGrouping(by: "created_at", bucket: .week))
    }

    @Test func aQueryThatNamesNothingListsEveryTypeAndBothTiers() throws {
        let view = try read(["title": "All", "layouts": [["id": "rows", "kind": "list"]]])
        #expect(view.settings.query == ViewQuery())
        #expect(view.settings.query.tier == nil && view.settings.query.states == nil)
    }

    @Test(
        arguments: [
            ("a title that is not text", ["title": 3, "layouts": [["id": "a", "kind": "list"]]], "title"),
            ("no layouts", ["title": "t", "layouts": []], "layouts"),
            (
                "a layout of an unknown kind", ["title": "t", "layouts": [["id": "a", "kind": "kanban"]]],
                "layouts.0.kind"
            ),
            ("a board with no group", ["title": "t", "layouts": [["id": "a", "kind": "board"]]], "layouts.0.group"),
            (
                "a timeline with no end",
                ["title": "t", "layouts": [["id": "a", "kind": "timeline", "start": "created_at"]]], "layouts.0.end"
            ),
            (
                "a sort in no direction",
                [
                    "title": "t",
                    "layouts": [["id": "a", "kind": "list", "sort": [["by": "title", "direction": "up"]]]],
                ],
                "layouts.0.sort.0.direction"
            ),
            (
                "a bucket of no span",
                [
                    "title": "t",
                    "layouts": [["id": "a", "kind": "list", "group": ["by": "created_at", "bucket": "hour"]]],
                ],
                "layouts.0.group.bucket"
            ),
            (
                "a tier no view lists",
                ["title": "t", "query": ["tier": "everywhere"], "layouts": [["id": "a", "kind": "list"]]], "query.tier"
            ),
        ] as [(String, JSONObject, String)])
    func settingsThisBuildCannotReadNameTheSettingAndTheView(_ what: String, _ settings: JSONObject, _ path: String)
        throws
    {
        #expect(throws: Marfa.MarfaError.self, "\(what) is refused") { try read(settings) }
        do {
            _ = try read(settings)
        } catch let error as Marfa.MarfaError {
            guard case .invalid(let message) = error else {
                Issue.record("\(what) was refused as \(error)")
                return
            }
            #expect(message.contains("view") && message.contains(path), "\(message)")
        }
    }

    @Test func aCopyThatHoldsNoViewReadsNoneAndRefusesTheRest() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        #expect(try await copy.items.view("01a00000-0000-7000-8000-000000000001") == nil)
        for read in [
            { _ = try await copy.items.list(inView: "01a00000-0000-7000-8000-000000000001") },
            { _ = try await copy.items.groups(inView: "01a00000-0000-7000-8000-000000000001", layout: "main") },
            { _ = try await copy.search("x", inView: "01a00000-0000-7000-8000-000000000001") },
        ] as [() async throws -> Void] {
            await #expect {
                try await read()
            } throws: { error in
                if case .notFound(let code, _) = error as? Marfa.MarfaError { code == "not_held" } else { false }
            }
        }
        await copy.close()
    }
}

/// A core whose reads answer from a copy a hydration is still filling, or from a whole one.
private final class FillingCore: Core, @unchecked Sendable {
    let completeness: MarfaCore.Completeness

    init(_ completeness: MarfaCore.Completeness) {
        self.completeness = completeness
        super.init(noHandle: .init())
    }

    required init(unsafeFromHandle handle: UInt64) {
        fatalError("a fake core has no handle")
    }

    override func heldHandle() -> MarfaCore.Handle { .writer }

    static let item = Item(
        id: "i", type: "core.task", properties: [:], state: .active, tier: .library, version: 1, schemaVersion: 1,
        source: "test", sourceId: nil, occurredAt: "", createdAt: "", updatedAt: "", tags: [])

    override func list(filters: ListFilters, sort: MarfaCore.Sort) throws -> MarfaCore.Listing {
        Listing(items: [Self.item], completeness: completeness)
    }

    override func search(query: String, filters: SearchFilters, limit: UInt32) throws -> MarfaCore.Found {
        Found(hits: [SearchHit(item: Self.item, score: 1, snippet: "")], completeness: completeness)
    }

    override func listViews() throws -> MarfaCore.Views {
        Views(
            views: [
                ViewRow(
                    id: "v", version: 1, state: .active,
                    settings: ["title": "t", "layouts": [["id": "a", "kind": "list"]]])
            ], completeness: completeness)
    }

    override func listInView(id: String, layout: String?, limit: UInt32?, offset: UInt32?) throws
        -> MarfaCore.Listing
    {
        Listing(items: [Self.item], completeness: completeness)
    }

    override func searchInView(query: String, id: String, limit: UInt32) throws -> MarfaCore.Found {
        Found(hits: [SearchHit(item: Self.item, score: 1, snippet: "")], completeness: completeness)
    }

    override func viewGroups(id: String, layout: String, timeZone: String?) throws -> MarfaCore.ViewGroups {
        ViewGroups(groups: [ViewGroup(key: .null, count: 1, sum: nil)], completeness: completeness)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ReadsOfAFillingCopy {
    private static let reads: [(String, @Sendable (WorkingCopy) async throws -> Int)] = [
        ("items.list", { try await $0.items.list().count }),
        ("search", { try await $0.search("x").count }),
        ("items.views", { try await $0.items.views().count }),
        ("items.list(inView:)", { try await $0.items.list(inView: "v").count }),
        ("search(inView:)", { try await $0.search("x", inView: "v").count }),
        ("items.groups(inView:)", { try await $0.items.groups(inView: "v", layout: "a").count }),
    ]

    @Test func aReadFromACopyAHydrationStillFillsIsRefusedNeverAnsweredInPart() async throws {
        let copy = WorkingCopy(holder: CoreHolder(FillingCore(.partial)), hasServer: false)
        for (call, read) in Self.reads {
            await #expect("\(call) is refused") {
                _ = try await read(copy)
            } throws: { error in
                if case .hydrationIncomplete = error as? Marfa.MarfaError { true } else { false }
            }
        }
        await copy.close()
    }

    @Test func theSameReadsAnswerFromAWholeCopy() async throws {
        let copy = WorkingCopy(holder: CoreHolder(FillingCore(.complete)), hasServer: false)
        for (call, read) in Self.reads {
            #expect(try await read(copy) == 1, "\(call)")
        }
        await copy.close()
    }
}

extension Live {
    /// Creates a view through the server's view door, past the working copy.
    static func writeView(_ settings: JSONObject) async throws -> String {
        let server = try #require(server)
        var request = URLRequest(url: server.url.appending(path: "views"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(server.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(try settings.json().utf8)
        let (body, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        try #require(status == 201, "creating a view answered \(status ?? 0): \(String(decoding: body, as: UTF8.self))")
        let answered = try JSONObject(json: String(decoding: body, as: UTF8.self))
        return try #require(answered["item"]?.object?["id"]?.string)
    }

    static func deleteView(_ id: String) async throws {
        let server = try #require(server)
        var request = URLRequest(url: server.url.appending(path: "views/\(id)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(server.key)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
    }
}

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveViews {
        /// Tasks a view lists by a tag of their own, so other suites' tasks never show in it.
        struct Board {
            let copy: WorkingCopy
            let tag: String
            let view: String
            let ids: [String: String]

            static func make(_ tasks: [(title: String, status: String)]) async throws -> Board {
                let tag = "board\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
                let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
                _ = try await copy.hydrate(types: ["core.task", "system.view"], tier: .all)
                var ids: [String: String] = [:]
                for task in tasks {
                    ids[task.title] = try #require(
                        try await copy.items.create(
                            Draft(
                                type: "core.task",
                                properties: ["title": .string(task.title), "status": .string(task.status)],
                                tags: [tag], tier: .library)
                        ).itemId)
                }
                _ = try await copy.queue.drain()
                let view = try await Live.writeView([
                    "title": .string("Tasks \(tag)"),
                    "query": ["types": ["core.task"], "filter": .string("tags contains \"\(tag)\"")],
                    "layouts": [
                        [
                            "id": "board", "kind": "board",
                            "group": ["by": "properties.status", "order": ["todo", "done"]],
                            "sort": [["by": "properties.title", "direction": "asc"]],
                        ],
                        ["id": "newest", "kind": "list", "sort": [["by": "properties.title", "direction": "desc"]]],
                    ],
                ])
                _ = try await copy.hydrate(types: ["core.task", "system.view"], tier: .all)
                return Board(copy: copy, tag: tag, view: view, ids: ids)
            }
        }

        @Test func aViewIsReadWithItsLayoutsItemsAndGroups() async throws {
            let board = try await Board.make([("b", "todo"), ("a", "todo"), ("c", "done"), ("d", "later")])
            let copy = board.copy

            let view = try #require(try await copy.items.view(board.view))
            #expect(
                view.version == 1 && view.state == .active && view.settings.layouts.map(\.id) == ["board", "newest"])
            #expect(view.settings.layouts[0].kind == .board)
            #expect(view.settings.layouts[0].group?.order == ["todo", "done"])
            #expect(try await copy.items.views().map(\.id).contains(board.view))

            #expect(
                try await copy.items.list(inView: board.view, layout: "board").map(\.title) == ["a", "b", "c", "d"],
                "the board's own sort")
            #expect(
                try await copy.items.list(inView: board.view, layout: "newest").map(\.title) == ["d", "c", "b", "a"],
                "another layout, another sort")
            #expect(
                try await copy.items.list(inView: board.view).map(\.title) == ["a", "b", "c", "d"],
                "no layout is the first")
            #expect(
                try await copy.items.list(inView: board.view, layout: "newest", limit: 2, offset: 1).map(\.title)
                    == ["c", "b"], "a page of the sorted whole")

            let groups = try await copy.items.groups(inView: board.view, layout: "board")
            #expect(groups.map(\.key) == ["todo", "done", "later"], "the named groups first, then the rest")
            #expect(groups.map(\.count) == [2, 1, 1])
            #expect(groups.allSatisfy { $0.sum == nil })

            #expect(try await copy.search("a", inView: board.view).allSatisfy { $0.item.tags.contains(board.tag) })
            try await Live.deleteView(board.view)
            await copy.close()
        }

        @Test func aLiveQueryOverALayoutFollowsItemsEnteringLeavingAndChangingGroup() async throws {
            let board = try await Board.make([("a", "todo"), ("b", "todo"), ("c", "done")])
            let copy = board.copy
            let groups = await LiveQuery(copy, reading: .groups(inView: board.view, layout: "board"))
            let items = await LiveQuery(copy, reading: .list(inView: board.view, layout: "board"))
            func counts() async -> [String: UInt64] {
                await Dictionary(
                    uniqueKeysWithValues: groups.value.compactMap { group in
                        group.key.string.map { ($0, group.count) }
                    })
            }
            try await eventually("the first read ended") {
                let loading = [await groups.isLoading, await items.isLoading]
                return !loading.contains(true)
            }
            #expect(await counts() == ["todo": 2, "done": 1])
            #expect(await items.value.map(\.title) == ["a", "b", "c"])

            let entered = try await copy.items.create(
                Draft(
                    type: "core.task", properties: ["title": "d", "status": "todo"], tags: [board.tag], tier: .library))
            let enteredId = try #require(entered.itemId)
            try await eventually("an item entering shows in its group") { await counts() == ["todo": 3, "done": 1] }
            try await eventually("and in the layout's sort") { await items.value.map(\.title) == ["a", "b", "c", "d"] }

            let moved = try #require(board.ids["a"])
            _ = try await copy.items.update(
                moved,
                Edit(properties: ["status": "done"], baseVersion: try #require(try await copy.items.get(moved)).version)
            )
            try await eventually("an item changing group moves between counts") {
                await counts() == ["todo": 2, "done": 2]
            }
            #expect(await groups.error == nil)

            _ = try await copy.tags.remove(board.tag, from: enteredId)
            try await eventually("an item leaving the view leaves its group") {
                await counts() == ["todo": 1, "done": 2]
            }
            try await eventually("and the layout") { await items.value.map(\.title) == ["a", "b", "c"] }

            _ = try await copy.queue.drain()
            let other = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await other.hydrate(types: ["core.task"], tier: .library)
            let changed = try #require(board.ids["b"])
            _ = try await other.items.update(
                changed,
                Edit(
                    properties: ["status": "later"],
                    baseVersion: try #require(try await other.items.get(changed)).version))
            _ = try await other.queue.drain()
            _ = try await copy.catchUp()
            try await eventually("a change the server tells moves the item too") {
                let now = await counts()
                return now["later"] == 1 && now["done"] == 2 && now["todo", default: 0] == 0
            }
            let errors = [await groups.error == nil, await items.error == nil]
            #expect(!errors.contains(false))

            try await Live.deleteView(board.view)
            await other.close()
            await copy.close()
        }

        @Test func aViewTheCopyCannotAnswerWholeIsRefusedWithItsReason() async throws {
            let board = try await Board.make([("a", "todo")])
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await copy.hydrate(types: ["core.note", "system.view"], tier: .all)
            let reason: @Sendable (Error) -> Bool = { error in
                if case .invalid(let message) = error as? Marfa.MarfaError {
                    message.contains("core.task")
                } else {
                    false
                }
            }
            await #expect(performing: { _ = try await copy.items.list(inView: board.view) }, throws: reason)
            await #expect(
                performing: { _ = try await copy.items.groups(inView: board.view, layout: "board") }, throws: reason)
            await #expect(performing: { _ = try await copy.search("a", inView: board.view) }, throws: reason)
            #expect(try await copy.items.view(board.view) != nil, "the view itself is still read")

            _ = try await copy.hydrate(types: ["core.task", "system.view"], tier: .all)
            #expect(
                try await copy.items.list(inView: board.view).map(\.title) == ["a"], "the witness: held whole, answered"
            )
            await #expect {
                _ = try await copy.items.list(inView: board.view, layout: "missing")
            } throws: { error in
                if case .invalid(let message) = error as? Marfa.MarfaError {
                    message.contains("missing")
                } else {
                    false
                }
            }
            try await Live.deleteView(board.view)
            await copy.close()
            await board.copy.close()
        }
    }
}
