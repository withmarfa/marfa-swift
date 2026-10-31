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
        "sort": [
            ["by": "properties.status", "direction": "desc"], ["by": "created_at", "direction": "asc"],
        ],
        "group": ["by": "properties.status", "order": ["todo", nil, 3], "hidden": [false]],
    ]

    private func read(_ settings: JSONObject = Self.settings) throws -> SavedView {
        try SavedView(
            MarfaCore.ViewRow(id: "view", version: 4, state: .active, settings: settings.core))
    }

    @Test func aViewKeepsItsQuerySortAndGroup() throws {
        let view = try read()
        #expect(view.id == "view" && view.version == 4 && view.state == .active)
        #expect(view.settings.title == "Everything")
        #expect(
            view.settings.query
                == ViewQuery(
                    types: ["core.task"], tier: .feed, states: [.archived], filter: "tags contains \"x\"",
                    beneath: "parent"))
        #expect(
            view.settings.sort == [
                ViewSort(by: "properties.status", direction: .descending),
                ViewSort(by: "created_at", direction: .ascending),
            ], "the keys in their declared order")
        #expect(
            view.settings.group
                == ViewGrouping(by: "properties.status", order: ["todo", nil, 3], hidden: [false]))
    }

    @Test func aViewWithNoSortReadsEmptyAndOneWithNoGroupReadsNil() throws {
        let bare = try read(["title": "Bare"])
        #expect(bare.settings.sort.isEmpty && bare.settings.group == nil)
        let sorted = try read(["title": "Sorted", "sort": [["by": "title", "direction": "asc"]]])
        #expect(sorted.settings.sort == [ViewSort(by: "title", direction: .ascending)] && sorted.settings.group == nil)
        let dated = try read(["title": "Dated", "group": ["by": "created_at", "bucket": "week"]])
        #expect(dated.settings.group == ViewGrouping(by: "created_at", bucket: .week) && dated.settings.sort.isEmpty)
    }

    @Test func aQueryThatNamesNothingListsEveryTypeAndBothTiers() throws {
        let view = try read(["title": "All"])
        #expect(view.settings.query == ViewQuery())
        #expect(view.settings.query.tier == nil && view.settings.query.states == nil)
    }

    @Test(
        arguments: [
            ("a title that is not text", ["title": 3], "title"),
            ("a sort that is not a list", ["title": "t", "sort": "title"], "sort"),
            (
                "a sort in no direction", ["title": "t", "sort": [["by": "title", "direction": "up"]]],
                "sort.0.direction"
            ),
            ("a sort with no field", ["title": "t", "sort": [["direction": "asc"]]], "sort.0.by"),
            ("a group that is not an object", ["title": "t", "group": "type"], "group"),
            ("a bucket of no span", ["title": "t", "group": ["by": "created_at", "bucket": "hour"]], "group.bucket"),
            ("a tier no view lists", ["title": "t", "query": ["tier": "everywhere"]], "query.tier"),
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
            { _ = try await copy.items.groups(inView: "01a00000-0000-7000-8000-000000000001") },
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
final class FillingCore: Core, @unchecked Sendable {
    let completeness: MarfaCore.Completeness

    init(_ completeness: MarfaCore.Completeness) {
        self.completeness = completeness
        super.init(noHandle: .init())
    }

    required init(unsafeFromHandle handle: UInt64) {
        fatalError("a fake core has no handle")
    }

    override func heldHandle() -> MarfaCore.Handle { .writer }

    static let item = MarfaCore.Item(
        id: "i", type: "core.task", properties: MarfaCore.JsonObject(members: []), state: .active, tier: .library,
        version: 1, schemaVersion: 1,
        source: "test", sourceId: nil, occurredAt: "", createdAt: "", updatedAt: "", tags: [])

    override func list(filters: MarfaCore.ListFilters, sort: MarfaCore.Sort?) throws -> MarfaCore.Listing {
        Listing(items: [Self.item], completeness: completeness)
    }

    override func search(query: String, filters: MarfaCore.SearchFilters, limit: UInt32) throws -> MarfaCore.Found {
        Found(hits: [MarfaCore.SearchHit(item: Self.item, score: 1, snippet: "")], completeness: completeness)
    }

    override func get(id: String) throws -> MarfaCore.Item? {
        if id == Self.item.id { return Self.item }
        if completeness == .partial { throw MarfaCore.MarfaError.HydrationIncomplete(message: "still filling") }
        return nil
    }

    override func listViews() throws -> MarfaCore.Views {
        Views(
            views: [
                MarfaCore.ViewRow(
                    id: "v", version: 1, state: .active,
                    settings: MarfaCore.JsonObject(members: [MarfaCore.JsonMember(key: "title", value: .string("t"))]))
            ], completeness: completeness)
    }

    override func listInView(id: String, limit: UInt32?, offset: UInt32?) throws
        -> MarfaCore.Listing
    {
        Listing(items: [Self.item], completeness: completeness)
    }

    override func searchInView(query: String, id: String, limit: UInt32) throws -> MarfaCore.Found {
        Found(hits: [MarfaCore.SearchHit(item: Self.item, score: 1, snippet: "")], completeness: completeness)
    }

    override func viewGroups(id: String, timeZone: String?) throws -> MarfaCore.ViewGroups {
        ViewGroups(groups: [MarfaCore.ViewGroup(key: .null, count: 1)], completeness: completeness)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ReadsOfAFillingCopy {
    private static func shape<Row>(_ rows: Rows<Row>) -> (count: Int, Marfa.Completeness) {
        (rows.count, rows.completeness)
    }

    private static let reads: [(String, @Sendable (WorkingCopy) async throws -> (count: Int, Marfa.Completeness))] = [
        ("items.list", { shape(try await $0.items.list()) }),
        ("search", { shape(try await $0.search("x")) }),
        ("items.views", { shape(try await $0.items.views()) }),
        ("items.list(inView:)", { shape(try await $0.items.list(inView: "v")) }),
        ("search(inView:)", { shape(try await $0.search("x", inView: "v")) }),
        ("items.groups(inView:)", { shape(try await $0.items.groups(inView: "v")) }),
    ]

    @Test func aReadFromACopyAHydrationStillFillsAnswersTheRowsThatArrivedMarkedPartial() async throws {
        let copy = WorkingCopy(holder: CoreHolder(FillingCore(.partial)), hasServer: false)
        for (call, read) in Self.reads {
            let (count, completeness) = try await read(copy)
            #expect(count == 1, "\(call) answers the row that arrived")
            #expect(completeness == .partial, "\(call) says it is partial")
        }
        await copy.close()
    }

    @Test func aReadFromACopyWhoseCursorAgedOutAnswersWhatItHeldMarkedStale() async throws {
        let copy = WorkingCopy(holder: CoreHolder(FillingCore(.stale)), hasServer: false)
        for (call, read) in Self.reads {
            let (count, completeness) = try await read(copy)
            #expect(count == 1, "\(call) answers the row the copy held")
            #expect(completeness == .stale, "\(call) says it is stale")
        }
        await copy.close()
    }

    @Test func theSameReadsOfAWholeCopyAreComplete() async throws {
        let copy = WorkingCopy(holder: CoreHolder(FillingCore(.complete)), hasServer: false)
        for (call, read) in Self.reads {
            let (count, completeness) = try await read(copy)
            #expect(count == 1, "\(call)")
            #expect(completeness == .complete, "\(call)")
        }
        await copy.close()
    }

    @Test func aReadByIDOfARowNotYetHeldThrowsAsTheCoreDoes() async throws {
        let copy = WorkingCopy(holder: CoreHolder(FillingCore(.partial)), hasServer: false)
        await #expect("a get of a row that has not arrived is refused") {
            _ = try await copy.items.get("not-yet")
        } throws: { error in
            if case .hydrationIncomplete = error as? Marfa.MarfaError { true } else { false }
        }
        #expect(try await copy.items.get("i") == Marfa.Item(FillingCore.item))
        let whole = WorkingCopy(holder: CoreHolder(FillingCore(.complete)), hasServer: false)
        #expect(try await whole.items.get("not-yet") == nil)
        await copy.close()
        await whole.close()
    }

    @MainActor @Test func aLiveQueryShowsTheCompletenessOfItsLastRead() async throws {
        let copy = WorkingCopy(holder: CoreHolder(FillingCore(.partial)), hasServer: false)
        let query = LiveQuery(copy, reading: Reading<Rows<Marfa.Item>>.list())
        #expect(query.value.isEmpty && query.value.completeness == .partial, "nothing is read yet")
        await query.refresh()
        #expect(query.value.count == 1 && query.value.completeness == .partial)

        let whole = WorkingCopy(holder: CoreHolder(FillingCore(.complete)), hasServer: false)
        let settled = LiveQuery(whole, reading: Reading<Rows<Marfa.Item>>.list())
        await settled.refresh()
        #expect(settled.value.count == 1 && settled.value.completeness == .complete)
        await copy.close()
        await whole.close()
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

            static func make(
                _ tasks: [(title: String, status: String)],
                sort: JSONValue = [["by": "properties.title", "direction": "asc"]],
                hidden: [JSONValue] = []
            ) async throws -> Board {
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
                    "sort": sort,
                    "group": [
                        "by": "properties.status", "order": ["not_started", "completed"], "hidden": .array(hidden),
                    ],
                ])
                _ = try await copy.hydrate(types: ["core.task", "system.view"], tier: .all)
                return Board(copy: copy, tag: tag, view: view, ids: ids)
            }
        }

        @Test func aViewIsReadWithItsSortItemsAndGroups() async throws {
            let board = try await Board.make([
                ("b", "not_started"), ("a", "not_started"), ("c", "completed"), ("d", "in_progress"),
            ])
            let copy = board.copy

            let view = try #require(try await copy.items.view(board.view))
            #expect(view.version == 1 && view.state == .active)
            #expect(view.settings.sort == [ViewSort(by: "properties.title", direction: .ascending)])
            #expect(view.settings.group?.order == ["not_started", "completed"])
            #expect(try await copy.items.views().map(\.id).contains(board.view))

            #expect(
                try await copy.items.list(inView: board.view).map(\.title) == ["a", "b", "c", "d"], "the view's sort")
            #expect(
                try await copy.items.list(inView: board.view, limit: 2, offset: 1).map(\.title) == ["b", "c"],
                "a page of the sorted whole")

            let groups = try await copy.items.groups(inView: board.view)
            #expect(
                groups.map(\.key) == ["not_started", "completed", "in_progress"],
                "the named groups first, then the rest")
            #expect(groups.map(\.count) == [2, 1, 1])

            #expect(try await copy.search("a", inView: board.view).allSatisfy { $0.item.tags.contains(board.tag) })
            try await Live.deleteView(board.view)
            await copy.close()
        }

        @Test func aViewWithNoSortOrGroupListsEveryItemInOneGroup() async throws {
            let board = try await Board.make([("b", "not_started"), ("a", "completed")])
            let bare = try await Live.writeView([
                "title": .string("Bare \(board.tag)"),
                "query": ["types": ["core.task"], "filter": .string("tags contains \"\(board.tag)\"")],
            ])
            _ = try await board.copy.hydrate(types: ["core.task", "system.view"], tier: .all)
            let view = try #require(try await board.copy.items.view(bare))
            #expect(view.settings.sort.isEmpty && view.settings.group == nil)
            #expect(try await board.copy.items.list(inView: bare).compactMap(\.title).sorted() == ["a", "b"])
            let groups = try await board.copy.items.groups(inView: bare)
            #expect(groups.map(\.key) == [.null] && groups.map(\.count) == [2], "the view groups nothing")

            let sorted = try await Live.writeView([
                "title": .string("Sorted \(board.tag)"),
                "query": ["types": ["core.task"], "filter": .string("tags contains \"\(board.tag)\"")],
                "sort": [["by": "properties.title", "direction": "desc"]],
            ])
            _ = try await board.copy.hydrate(types: ["core.task", "system.view"], tier: .all)
            #expect(try await board.copy.items.list(inView: sorted).map(\.title) == ["b", "a"], "sort without group")
            #expect(try await board.copy.items.view(sorted)?.settings.group == nil)
            for id in [board.view, bare, sorted] { try await Live.deleteView(id) }
            await board.copy.close()
        }

        @Test func aHiddenGroupLeavesTheGroupsAndNotTheItems() async throws {
            let board = try await Board.make(
                [("a", "not_started"), ("b", "completed"), ("c", "in_progress")], hidden: ["completed"])
            let copy = board.copy
            let view = try #require(try await copy.items.view(board.view))
            #expect(view.settings.group?.hidden == ["completed"])
            #expect(try await copy.items.groups(inView: board.view).map(\.key) == ["not_started", "in_progress"])
            #expect(
                try await copy.items.list(inView: board.view).map(\.title) == ["a", "b", "c"],
                "the witness: the view still lists the hidden group's items")
            try await Live.deleteView(board.view)
            await copy.close()
        }

        @Test func aLiveQueryOverAViewFollowsItemsEnteringLeavingAndChangingGroup() async throws {
            let board = try await Board.make([("a", "not_started"), ("b", "not_started"), ("c", "completed")])
            let copy = board.copy
            let groups = await LiveQuery(copy, reading: .groups(inView: board.view))
            let items = await LiveQuery(copy, reading: .list(inView: board.view))
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
            #expect(await counts() == ["not_started": 2, "completed": 1])
            #expect(await items.value.map(\.title) == ["a", "b", "c"])

            let entered = try await copy.items.create(
                Draft(
                    type: "core.task", properties: ["title": "d", "status": "not_started"], tags: [board.tag],
                    tier: .library))
            let enteredId = try #require(entered.itemId)
            try await eventually("an item entering shows in its group") {
                await counts() == ["not_started": 3, "completed": 1]
            }
            try await eventually("and in the view's sort") { await items.value.map(\.title) == ["a", "b", "c", "d"] }

            let moved = try #require(board.ids["a"])
            _ = try await copy.items.update(
                moved,
                Edit(
                    properties: ["status": "completed"],
                    baseVersion: try #require(try await copy.items.get(moved)).version)
            )
            try await eventually("an item changing group moves between counts") {
                await counts() == ["not_started": 2, "completed": 2]
            }
            #expect(await groups.error == nil)

            _ = try await copy.tags.remove(board.tag, from: enteredId)
            try await eventually("an item leaving the view leaves its group") {
                await counts() == ["not_started": 1, "completed": 2]
            }
            try await eventually("and the view") { await items.value.map(\.title) == ["a", "b", "c"] }

            _ = try await copy.queue.drain()
            let other = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await other.hydrate(types: ["core.task"], tier: .library)
            let changed = try #require(board.ids["b"])
            _ = try await other.items.update(
                changed,
                Edit(
                    properties: ["status": "in_progress"],
                    baseVersion: try #require(try await other.items.get(changed)).version))
            _ = try await other.queue.drain()
            _ = try await copy.catchUp()
            try await eventually("a change the server tells moves the item too") {
                let now = await counts()
                return now["in_progress"] == 1 && now["completed"] == 2 && now["not_started", default: 0] == 0
            }
            let errors = [await groups.error == nil, await items.error == nil]
            #expect(!errors.contains(false))

            try await Live.deleteView(board.view)
            await other.close()
            await copy.close()
        }

        @Test func aViewFilteredByABackrefIsAnsweredWhereTheCopyHoldsThatEdgeTypeWhole() async throws {
            let board = try await Board.make([
                ("parent", "not_started"), ("child", "not_started"), ("loner", "not_started"),
            ])
            let copy = board.copy
            _ = try await copy.edges.create(
                from: try #require(board.ids["parent"]), to: try #require(board.ids["child"]), type: "parent-of")
            _ = try await copy.queue.drain()
            let view = try await Live.writeView([
                "title": .string("Children \(board.tag)"),
                "query": [
                    "types": ["core.task"],
                    "filter": .string("tags contains \"\(board.tag)\" AND backref[parent-of] exists"),
                ],
            ])
            let fresh = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await fresh.hydrate(types: ["core.task", "system.view"], tier: .all)
            await #expect {
                _ = try await fresh.items.list(inView: view)
            } throws: { error in
                if case .invalid = error as? Marfa.MarfaError { true } else { false }
            }
            _ = try await fresh.hydrate(types: ["core.task", "system.view"], tier: .all, edgeTypes: ["parent-of"])
            #expect(try await fresh.items.list(inView: view).compactMap(\.title) == ["child"])
            for id in [view, board.view] { try await Live.deleteView(id) }
            await fresh.close()
            await copy.close()
        }

        @Test func aViewTheCopyCannotAnswerWholeIsRefusedWithItsReason() async throws {
            let board = try await Board.make([("a", "not_started")])
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
                performing: { _ = try await copy.items.groups(inView: board.view) }, throws: reason)
            await #expect(performing: { _ = try await copy.search("a", inView: board.view) }, throws: reason)
            #expect(try await copy.items.view(board.view) != nil, "the view itself is still read")

            _ = try await copy.hydrate(types: ["core.task", "system.view"], tier: .all)
            #expect(
                try await copy.items.list(inView: board.view).map(\.title) == ["a"], "the witness: held whole, answered"
            )
            try await Live.deleteView(board.view)
            await copy.close()
            await board.copy.close()
        }
    }
}
