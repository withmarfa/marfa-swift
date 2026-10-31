#if DEBUG
import Foundation
import Marfa
import MarfaTesting
import Testing

/// What the fake answers for saved views.
///
/// A real copy writes a view only through a server, so these run on the fake alone.
@Suite(.timeLimit(.minutes(1)))
struct FakeViews {
    static func note(
        _ number: Int, _ title: String, type: String = "core.note", state: ItemState = .active, tier: Tier = .library,
        tags: [String] = [], at day: Int = 1, rank: JSONValue? = nil
    ) -> Item {
        let at = "2026-09-\(String(format: "%02d", day))T10:00:00.000Z"
        var properties: JSONObject = ["title": .string(title)]
        if let rank { properties["rank"] = rank }
        return Item(
            id: "01a1500d-78bd-73f0-8c55-2a4160c5ff0\(number)", type: type, properties: properties, state: state,
            tier: tier, version: 1, schemaVersion: 1, source: "app", sourceId: nil, occurredAt: at, createdAt: at,
            updatedAt: at, tags: tags, title: title, body: nil)
    }

    static let a = note(1, "a", tags: ["x"], at: 1, rank: 3)
    static let b = note(2, "b", tags: ["x", "y"], at: 2, rank: 1)
    static let c = note(3, "c", state: .archived, at: 3, rank: "two")
    static let d = note(4, "d", tier: .feed, at: 4)
    static let e = note(5, "e", state: .trashed, at: 5)
    static let task = note(6, "t", type: "core.task", at: 6)
    static let parent = Edge(
        id: "01a1500d-78bd-73f0-8c55-2a4160c5ffe1", sourceId: a.id, targetId: b.id, edgeType: "parent-of",
        properties: [:], version: 1, createdAt: a.createdAt, updatedAt: a.createdAt)
    static let nested = Edge(
        id: "01a1500d-78bd-73f0-8c55-2a4160c5ffe2", sourceId: b.id, targetId: c.id, edgeType: "parent-of",
        properties: [:], version: 1, createdAt: a.createdAt, updatedAt: a.createdAt)

    static func fake(views: [SavedView] = []) -> FakeCopy {
        WorkingCopy.fake(items: [a, b, c, d, e, task], edges: [parent, nested], views: views)
    }

    func titles(_ copy: WorkingCopy, _ settings: ViewSettings) async throws -> [String] {
        let view = try await copy.createView(settings)
        return try await copy.items.list(inView: view.id).compactMap(\.title)
    }

    @Test func aViewIsWrittenAtOnceAndReadBack() async throws {
        let fake = Self.fake()
        let copy = fake.copy
        let heard = Heard(copy.changes())
        let sort = [ViewSort(by: "title", direction: .ascending)]

        let made = try await copy.createView(
            ViewSettings(title: "Notes", query: ViewQuery(types: ["core.note"]), sort: sort))
        #expect(made.version == 1 && made.state == .active)
        #expect(made.settings == ViewSettings(title: "Notes", query: ViewQuery(types: ["core.note"]), sort: sort))
        #expect(try await copy.items.view(made.id) == made)
        #expect(try await copy.items.views().map(\.id) == [made.id])
        #expect(try await copy.items.get(made.id)?.type == "system.view")

        let changed = try await copy.changeView(made.id, ViewSettingsChange(title: "Renamed"), baseVersion: 1)
        #expect(changed.version == 2 && changed.settings.title == "Renamed" && changed.settings.sort == sort)

        try await copy.deleteView(made.id)
        #expect(try await copy.items.view(made.id) == nil)
        #expect(try await copy.items.get(made.id) == nil)
        #expect(try await copy.items.views().isEmpty)

        #expect(fake.writes.isEmpty, "a view write is never queued")
        try await eventually("the three changes") { heard.all.count == 3 }
        #expect(
            heard.all == [
                Change(origin: .refreshed(.viewWritten), itemId: made.id, edgeId: nil),
                Change(origin: .refreshed(.viewWritten), itemId: made.id, edgeId: nil),
                Change(origin: .refreshed(.purged), itemId: made.id, edgeId: nil),
            ])
    }

    @Test func aStaleChangeMergesOrCollidesAsTheServerDoes() async throws {
        let copy = Self.fake().copy
        let made = try await copy.createView(
            ViewSettings(title: "V", group: ViewGrouping(by: "state")))
        _ = try await copy.changeView(made.id, ViewSettingsChange(title: "Renamed"), baseVersion: 1)

        let merged = try await copy.changeView(
            made.id, ViewSettingsChange(sort: [ViewSort(by: "title", direction: .descending)]), baseVersion: 1)
        #expect(merged.version == 3 && merged.settings.title == "Renamed" && merged.settings.sort.count == 1)

        await #expect {
            try await copy.changeView(made.id, ViewSettingsChange(title: "Lost"), baseVersion: 1)
        } throws: { error in
            if case .versionConflict? = error as? MarfaError { true } else { false }
        }
        #expect(try await copy.items.view(made.id)?.settings.title == "Renamed")

        let cleared = try await copy.changeView(made.id, ViewSettingsChange(group: .clear), baseVersion: 3)
        #expect(cleared.version == 4 && cleared.settings.group == nil && cleared.settings.title == "Renamed")
    }

    @Test func aStaleChangeSettingsEqualToTheBaseAreEchoes() async throws {
        let copy = Self.fake().copy
        let made = try await copy.createView(ViewSettings(title: "A"))
        _ = try await copy.changeView(made.id, ViewSettingsChange(title: "B"), baseVersion: 1)

        let sort = [ViewSort(by: "title", direction: .ascending)]
        let merged = try await copy.changeView(
            made.id, ViewSettingsChange(title: "A", sort: sort), baseVersion: 1)
        #expect(merged.version == 3 && merged.settings.title == "B" && merged.settings.sort == sort)
    }

    @Test func aViewWriteTheServerRefusesChangesNothing() async throws {
        let copy = Self.fake().copy
        let made = try await copy.createView(ViewSettings(title: "V"))
        let settings: [ViewSettings] = [
            ViewSettings(title: ""),
            ViewSettings(title: String(repeating: "a", count: 501)),
            ViewSettings(title: "V", query: ViewQuery(states: [])),
            ViewSettings(title: "V", query: ViewQuery(types: ["*"])),
            ViewSettings(title: "V", query: ViewQuery(beneath: "not-an-id")),
            ViewSettings(title: "V", sort: [ViewSort(by: "properties.9a", direction: .ascending)]),
            ViewSettings(title: "V", sort: [ViewSort(by: "properties.a-b", direction: .ascending)]),
        ]
        for refused in settings {
            await #expect {
                _ = try await copy.createView(refused)
            } throws: { error in
                guard case .validation(let code, _)? = error as? MarfaError else { return false }
                return code == "validation_error"
            }
        }
        await #expect(throws: MarfaError.self) {
            _ = try await copy.changeView(made.id, ViewSettingsChange(title: ""), baseVersion: 1)
        }
        await #expect(throws: MarfaError.self) {
            _ = try await copy.changeView(made.id, ViewSettingsChange(query: ViewQuery(states: [])), baseVersion: 1)
        }
        #expect(try await copy.items.views().map(\.id) == [made.id])
        #expect(try await copy.items.view(made.id)?.version == 1)

        let ok = try await copy.createView(
            ViewSettings(
                title: String(repeating: "a", count: 500),
                sort: [ViewSort(by: "properties._Rank9", direction: .ascending)]))
        #expect(ok.settings.title.count == 500)
    }

    @Test func aChangeOrDeleteOfWhatIsNotAViewIsRefused() async throws {
        let copy = Self.fake().copy
        let made = try await copy.createView(ViewSettings(title: "V"))
        for id in [Self.a.id, "01a1500d-78bd-73f0-8c55-2a4160c5ffff"] {
            await #expect {
                try await copy.changeView(id, ViewSettingsChange(title: "x"), baseVersion: 1)
            } throws: { error in
                guard case .notFound(let code, _)? = error as? MarfaError else { return false }
                return code == "item_not_found"
            }
            await #expect(throws: MarfaError.self) { try await copy.deleteView(id) }
        }
        await #expect(throws: MarfaError.self) {
            try await copy.changeView(made.id, ViewSettingsChange(), baseVersion: 1)
        }
        await #expect(throws: MarfaError.self) {
            _ = try await copy.createView(
                ViewSettings(title: "V", sort: (0..<11).map { _ in ViewSort(by: "title", direction: .ascending) }))
        }
        #expect(try await copy.items.get(Self.a.id) == Self.a)
    }

    @Test func aRetryWithTheSameKeyAnswersTheFirstWrite() async throws {
        let copy = Self.fake().copy
        let first = try await copy.createView(ViewSettings(title: "V"), idempotencyKey: "k")
        let again = try await copy.createView(ViewSettings(title: "V"), idempotencyKey: "k")
        #expect(first == again)
        #expect(try await copy.items.views().count == 1)
        try await copy.deleteView(first.id, idempotencyKey: "gone")
        try await copy.deleteView(first.id, idempotencyKey: "gone")
    }

    @Test func aViewListsWhatItsQueryHolds() async throws {
        let copy = Self.fake().copy
        let ascending = [ViewSort(by: "title", direction: .ascending)]

        // No state names active and archived; the trashed and the system.* rows never show.
        #expect(try await titles(copy, ViewSettings(title: "all", sort: ascending)) == ["a", "b", "c", "d", "t"])
        // A type takes its subtypes' names too, by name.
        #expect(
            try await titles(copy, ViewSettings(title: "t", query: ViewQuery(types: ["core.task"]), sort: ascending))
                == ["t"])
        #expect(
            try await titles(
                copy, ViewSettings(title: "core", query: ViewQuery(types: ["core.note", "core.task"]), sort: ascending))
                == ["a", "b", "c", "d", "t"])
        #expect(
            try await titles(
                copy, ViewSettings(title: "tier", query: ViewQuery(tier: .feed), sort: ascending)) == ["d"])
        #expect(
            try await titles(
                copy, ViewSettings(title: "state", query: ViewQuery(states: [.archived]), sort: ascending)) == ["c"])
        #expect(
            try await titles(
                copy, ViewSettings(title: "below", query: ViewQuery(beneath: Self.b.id), sort: ascending))
                == ["b", "c"])
    }

    @Test func aViewOrdersAsTheCoreOrders() async throws {
        let copy = Self.fake().copy
        let query = ViewQuery(types: ["core.note"])

        // The default is newest occurrence first.
        #expect(try await titles(copy, ViewSettings(title: "d", query: query)) == ["d", "c", "b", "a"])
        // A property sorts numbers before text, and an item without it last in either direction.
        for (direction, expected) in [
            (SortDirection.ascending, ["b", "a", "c", "d"]), (.descending, ["c", "a", "b", "d"]),
        ] {
            let sort = [ViewSort(by: "properties.rank", direction: direction)]
            #expect(try await titles(copy, ViewSettings(title: "r", query: query, sort: sort)) == expected)
        }
        // The next key breaks a tie on the first.
        let sort = [ViewSort(by: "state", direction: .ascending), ViewSort(by: "title", direction: .descending)]
        #expect(try await titles(copy, ViewSettings(title: "s", query: query, sort: sort)) == ["d", "b", "a", "c"])

        let view = try await copy.createView(ViewSettings(title: "p", query: query))
        #expect(try await copy.items.list(inView: view.id, limit: 2, offset: 1).compactMap(\.title) == ["c", "b"])
    }

    @Test func aViewGroupsItsItems() async throws {
        let copy = Self.fake().copy
        let query = ViewQuery(types: ["core.note"])
        func groups(_ grouping: ViewGrouping?) async throws -> [String] {
            let view = try await copy.createView(ViewSettings(title: "g", query: query, group: grouping))
            return try await copy.items.groups(inView: view.id).map { "\($0.key.string ?? "null"):\($0.count)" }
        }

        #expect(try await groups(nil) == ["null:4"])
        #expect(try await groups(ViewGrouping(by: "tags")) == ["x:2", "y:1", "null:2"])
        #expect(try await groups(ViewGrouping(by: "state", order: ["archived"])) == ["archived:1", "active:3"])
        #expect(try await groups(ViewGrouping(by: "state", hidden: ["active"])) == ["archived:1"])
        #expect(
            try await groups(ViewGrouping(by: "edge[parent-of]"))
                == ["\(Self.b.id):1", "\(Self.c.id):1", "null:2"])
        #expect(try await groups(ViewGrouping(by: "created_at", bucket: .month)) == ["2026-09-01:4"])
        let weeks = try await copy.createView(
            ViewSettings(title: "w", query: query, group: ViewGrouping(by: "created_at", bucket: .week)))
        let london = try await copy.items.groups(inView: weeks.id, timeZone: TimeZone(identifier: "Europe/London"))
        #expect(london.map(\.key.string) == ["2026-08-31"] && london.map(\.count) == [4])
    }

    @Test func aSeededViewIsServedAndARevokedOneIsNotEvaluated() async throws {
        let seeded = SavedView(
            id: "01a1500d-78bd-73f0-8c55-2a4160c5ff90", version: 5, state: .active,
            settings: ViewSettings(title: "Feed", query: ViewQuery(tier: .feed)))
        let revoked = SavedView(
            id: "01a1500d-78bd-73f0-8c55-2a4160c5ff91", version: 2, state: .revoked,
            settings: ViewSettings(title: "Gone"))
        let copy = Self.fake(views: [seeded, revoked]).copy

        #expect(try await copy.items.views().map(\.id).sorted() == [seeded.id, revoked.id])
        #expect(try await copy.items.view(seeded.id) == seeded)
        #expect(try await copy.items.list(inView: seeded.id).compactMap(\.title) == ["d"])
        let changed = try await copy.changeView(seeded.id, ViewSettingsChange(title: "Feed 2"), baseVersion: 5)
        #expect(changed.version == 6)
        await #expect {
            _ = try await copy.items.list(inView: revoked.id)
        } throws: { error in
            guard case .invalid? = error as? MarfaError else { return false }
            return true
        }
        await #expect {
            _ = try await copy.changeView(revoked.id, ViewSettingsChange(title: "x"), baseVersion: 2)
        } throws: { error in
            guard case .validation(let code, _)? = error as? MarfaError else { return false }
            return code == "invalid_transition"
        }
        try await copy.deleteView(revoked.id)
        #expect(try await copy.items.view(revoked.id) == nil)
        await #expect {
            _ = try await copy.items.list(inView: "01a1500d-78bd-73f0-8c55-2a4160c5ff99")
        } throws: { error in
            guard case .notFound(let code, _)? = error as? MarfaError else { return false }
            return code == "not_held"
        }
    }

    @Test func whatTheFakeCannotEvaluateIsRefusedNeverAnsweredWrong() async throws {
        let copy = Self.fake().copy
        let filtered = try await copy.createView(
            ViewSettings(title: "f", query: ViewQuery(filter: "properties.rank gt 1")))
        let refused: (String) -> (any Error) -> Bool = { call in
            { error in (error as? FakeCopyError) == .unsupported(call: call) }
        }
        await #expect(
            performing: { _ = try await copy.items.list(inView: filtered.id) },
            throws: refused("items.list(inView:) with a filter"))
        await #expect(
            performing: { _ = try await copy.items.groups(inView: filtered.id) },
            throws: refused("items.groups(inView:) with a filter"))
        await #expect(
            performing: { _ = try await copy.search("a", inView: filtered.id) },
            throws: refused("search(inView:) with a filter"))
    }

    @Test func aSearchInAViewFindsOnlyWhatTheViewListsAndRanksAmongEveryRow() async throws {
        let copy = Self.fake().copy
        let notes = try await copy.createView(ViewSettings(title: "n", query: ViewQuery(types: ["core.note"])))
        let tasks = try await copy.createView(ViewSettings(title: "t", query: ViewQuery(types: ["core.task"])))
        let tagged = try await copy.createView(ViewSettings(title: "x", query: ViewQuery(beneath: Self.a.id)))
        // a and b are active notes, c is archived, which a view lists by default; d is a feed note.
        #expect(Set(try await copy.search("b", inView: notes.id).compactMap(\.item.title)) == ["b"])
        #expect(try await copy.search("t", inView: tasks.id).compactMap(\.item.title) == ["t"])
        #expect(try await copy.search("t", inView: notes.id).isEmpty)
        #expect(Set(try await copy.search("c", inView: tagged.id).compactMap(\.item.title)) == ["c"])
        #expect(try await copy.search("d", inView: tagged.id).isEmpty)
        #expect(try await copy.search("e", inView: notes.id).isEmpty)
        #expect(try await copy.search("b", inView: notes.id, limit: 0).isEmpty)
        #expect(try await copy.search("b", inView: notes.id).completeness == .complete)
        await #expect(
            performing: { _ = try await copy.search("a", inView: "absent") },
            throws: { error in
                guard case .notFound(let code, _)? = error as? MarfaError else { return false }
                return code == "not_held"
            }
        )
    }
}
#endif
