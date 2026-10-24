import Foundation
import MarfaCore

/// What one group of a layout holds: its `key`, how many items are in it, and for a chart that sums a property, the
/// `sum`.
///
/// The key is the value the layout groups by: a string, number or boolean, a bucket's first date as `YYYY-MM-DD`, an
/// item id for an edge group, or `null` for the items that have none. An item with two tags is in both tag groups.
public typealias ViewGroup = MarfaCore.ViewGroup

/// A `system.view`: a saved list of items, and the layouts that show it.
///
/// It is not called `View`, which would be ambiguous with SwiftUI's in every file that imports both.
///
/// A view says which items to list in its ``ViewSettings/query`` and how each layout shows them, so every app shows
/// the same list the same way. Read one with ``Items/view(_:)``, its items with ``Items/list(inView:layout:limit:offset:)``
/// and its groups with ``Items/groups(inView:layout:timeZone:)``. ``WorkingCopy/createView(_:idempotencyKey:)``,
/// ``WorkingCopy/changeView(_:_:baseVersion:idempotencyKey:)`` and ``WorkingCopy/deleteView(_:idempotencyKey:)``
/// write one.
public struct SavedView: Sendable, Hashable, Identifiable {
    public let id: String
    public let version: Int64
    /// `.revoked` is final: the view changes no more.
    public let state: ItemState
    public let settings: ViewSettings

    init(_ core: MarfaCore.ViewRow) throws {
        id = core.id
        version = core.version
        state = core.state
        settings = try ViewSettings(core.settings, of: core.id)
    }
}

/// What a view lists, and how its layouts show it.
public struct ViewSettings: Sendable, Hashable {
    public var title: String
    public var query: ViewQuery
    /// In order, and at least one.
    public var layouts: [ViewLayout]

    public init(title: String, query: ViewQuery = ViewQuery(), layouts: [ViewLayout]) {
        self.title = title
        self.query = query
        self.layouts = layouts
    }

    init(_ core: JSONObject, of view: String) throws {
        let reader = ViewReader(view: view)
        title = try reader.string(core["title"], "title")
        query = try ViewQuery(reader.optionalObject(core["query"], "query"), reader)
        layouts = try reader.array(core["layouts"], "layouts").enumerated().map { index, layout in
            try ViewLayout(reader.object(layout, "layouts.\(index)"), reader, path: "layouts.\(index)")
        }
        guard !layouts.isEmpty else { throw reader.refusal("layouts", "holds no layout") }
    }
}

/// The query that decides which items a view lists.
public struct ViewQuery: Sendable, Hashable {
    /// Each with its subtypes; empty lists every type but `system.*`.
    public var types: [String]
    /// `nil` lists both tiers.
    public var tier: SliceTier?
    /// `nil` lists active and archived items.
    public var states: [ItemState]?
    /// An expression in the server's listing grammar.
    public var filter: String?
    /// An item id: that item and everything it reaches along `parent-of`.
    public var beneath: String?

    public init(
        types: [String] = [], tier: SliceTier? = nil, states: [ItemState]? = nil, filter: String? = nil,
        beneath: String? = nil
    ) {
        self.types = types
        self.tier = tier
        self.states = states
        self.filter = filter
        self.beneath = beneath
    }

    fileprivate init(_ core: JSONObject?, _ reader: ViewReader) throws {
        guard let core else {
            self.init()
            return
        }
        let tier = try reader.optionalString(core["tier"], "query.tier").map { text in
            guard let tier = SliceTier(wire: text) else { throw reader.refusal("query.tier", "is \(text)") }
            return tier
        }
        let states = try reader.optionalArray(core["state"], "query.state")?.map { state in
            let text = try reader.string(state, "query.state")
            switch text {
            case "active": return ItemState.active
            case "archived": return ItemState.archived
            default: throw reader.refusal("query.state", "holds \(text)")
            }
        }
        self.init(
            types: try reader.optionalArray(core["types"], "query.types")?.map { try reader.string($0, "query.types") }
                ?? [],
            tier: tier, states: states, filter: try reader.optionalString(core["filter"], "query.filter"),
            beneath: try reader.optionalString(core["beneath"], "query.beneath"))
    }
}

/// One way a view shows its items.
///
/// A layout never narrows which items a view lists.
public struct ViewLayout: Sendable, Hashable, Identifiable {
    /// Unique in the view, which an app keeps to reopen the layout.
    public var id: String
    public var kind: Kind
    /// `nil` where an app names the layout by its kind.
    public var title: String?
    /// The keys the layout sorts by, first key first.
    public var sort: [ViewSort]
    public var group: ViewGrouping?
    /// The fields the layout shows, in order.
    public var shown: [String]

    /// How a layout shows items.
    ///
    /// A kind carries the options it takes. Each option is a field: an own field such as `created_at` or `tags`,
    /// or `properties.<name>`.
    public enum Kind: Sendable, Hashable {
        case list
        case table
        /// Columns by the layout's ``ViewLayout/group``, which a board always has.
        case board
        /// Cards, with the property that holds each card's image.
        case gallery(image: String?)
        /// Items placed on `date`, as spans to `end` where both are set.
        case calendar(date: String?, end: String?)
        /// Items as spans from `start` to `end`.
        case timeline(start: String, end: String)
        /// Items along `x`, measured by `y`.
        case chart(x: String?, y: ViewMeasure?)
        /// Items at the place a property holds.
        case map(location: String?)
    }

    public init(
        id: String, kind: Kind, title: String? = nil, sort: [ViewSort] = [], group: ViewGrouping? = nil,
        shown: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.sort = sort
        self.group = group
        self.shown = shown
    }

    fileprivate init(_ core: JSONObject, _ reader: ViewReader, path: String) throws {
        let kindName = try reader.string(core["kind"], "\(path).kind")
        let kind: Kind
        switch kindName {
        case "list": kind = .list
        case "table": kind = .table
        case "board": kind = .board
        case "gallery": kind = .gallery(image: try reader.optionalString(core["image"], "\(path).image"))
        case "calendar":
            kind = .calendar(
                date: try reader.optionalString(core["date"], "\(path).date"),
                end: try reader.optionalString(core["end"], "\(path).end"))
        case "timeline":
            kind = .timeline(
                start: try reader.string(core["start"], "\(path).start"),
                end: try reader.string(core["end"], "\(path).end"))
        case "chart":
            kind = .chart(
                x: try reader.optionalString(core["x"], "\(path).x"),
                y: try core["y"].map { try ViewMeasure($0, reader, path: "\(path).y") })
        case "map": kind = .map(location: try reader.optionalString(core["location"], "\(path).location"))
        default: throw reader.refusal("\(path).kind", "is \(kindName)")
        }
        let group = try reader.optionalObject(core["group"], "\(path).group").map {
            try ViewGrouping($0, reader, path: "\(path).group")
        }
        if case .board = kind, group == nil { throw reader.refusal("\(path).group", "is missing from a board") }
        self.init(
            id: try reader.string(core["id"], "\(path).id"), kind: kind,
            title: try reader.optionalString(core["title"], "\(path).title"),
            sort: try reader.optionalArray(core["sort"], "\(path).sort")?.enumerated().map { index, sort in
                try ViewSort(reader.object(sort, "\(path).sort.\(index)"), reader, path: "\(path).sort.\(index)")
            } ?? [],
            group: group,
            shown: try reader.optionalArray(core["shown"], "\(path).shown")?.map {
                try reader.string($0, "\(path).shown")
            } ?? [])
    }
}

/// One key a layout sorts by.
public struct ViewSort: Sendable, Hashable {
    /// A field: an own field such as `created_at` or `tags`, or `properties.<name>`.
    public var by: String
    public var direction: SortDirection

    public init(by: String, direction: SortDirection) {
        self.by = by
        self.direction = direction
    }

    fileprivate init(_ core: JSONObject, _ reader: ViewReader, path: String) throws {
        let direction = try reader.string(core["direction"], "\(path).direction")
        switch direction {
        case "asc": self.init(by: try reader.string(core["by"], "\(path).by"), direction: .ascending)
        case "desc": self.init(by: try reader.string(core["by"], "\(path).by"), direction: .descending)
        default: throw reader.refusal("\(path).direction", "is \(direction)")
        }
    }
}

/// How a layout groups its items.
public struct ViewGrouping: Sendable, Hashable {
    /// A field, or `edge[<type>]` or `backref[<type>]` for the item an edge of that type joins.
    public var by: String
    /// For a date field, the span each group covers. `nil` groups by the value.
    public var bucket: Bucket?
    /// The keys whose groups come first, in this order.
    public var order: [JSONValue]
    /// The keys whose groups the layout leaves out.
    ///
    /// The layout still lists their items.
    public var hidden: [JSONValue]

    public enum Bucket: Sendable, Hashable, CaseIterable {
        case day
        /// Weeks begin on Monday.
        case week
        case month
        case year
    }

    public init(by: String, bucket: Bucket? = nil, order: [JSONValue] = [], hidden: [JSONValue] = []) {
        self.by = by
        self.bucket = bucket
        self.order = order
        self.hidden = hidden
    }

    fileprivate init(_ core: JSONObject, _ reader: ViewReader, path: String) throws {
        let bucket = try reader.optionalString(core["bucket"], "\(path).bucket").map { text in
            switch text {
            case "day": Bucket.day
            case "week": Bucket.week
            case "month": Bucket.month
            case "year": Bucket.year
            default: throw reader.refusal("\(path).bucket", "is \(text)")
            }
        }
        self.init(
            by: try reader.string(core["by"], "\(path).by"), bucket: bucket,
            order: try reader.optionalArray(core["order"], "\(path).order") ?? [],
            hidden: try reader.optionalArray(core["hidden"], "\(path).hidden") ?? [])
    }
}

/// What a chart measures.
public enum ViewMeasure: Sendable, Hashable {
    /// The number of items in each group.
    case count
    /// The total of a number property, `properties.<name>`, in each group.
    case sum(String)

    fileprivate init(_ core: JSONValue, _ reader: ViewReader, path: String) throws {
        if case .string("count") = core {
            self = .count
        } else {
            self = .sum(try reader.string(reader.object(core, path)["sum"], "\(path).sum"))
        }
    }
}

/// Reads a view's settings, and names the setting it could not read.
private struct ViewReader {
    let view: String

    func refusal(_ path: String, _ problem: String) -> MarfaError {
        .invalid(message: "the view \(view) cannot be read: \(path) \(problem)")
    }

    func string(_ value: JSONValue?, _ path: String) throws -> String {
        guard let text = value?.string else { throw refusal(path, "is not a string") }
        return text
    }

    func optionalString(_ value: JSONValue?, _ path: String) throws -> String? {
        try value.map { try string($0, path) }
    }

    func array(_ value: JSONValue?, _ path: String) throws -> [JSONValue] {
        guard let items = value?.array else { throw refusal(path, "is not an array") }
        return items
    }

    func optionalArray(_ value: JSONValue?, _ path: String) throws -> [JSONValue]? {
        try value.map { try array($0, path) }
    }

    func object(_ value: JSONValue?, _ path: String) throws -> JSONObject {
        guard let object = value?.object else { throw refusal(path, "is not an object") }
        return object
    }

    func optionalObject(_ value: JSONValue?, _ path: String) throws -> JSONObject? {
        try value.map { try object($0, path) }
    }
}

extension SliceTier {
    init?(wire: String) {
        switch wire {
        case "library": self = .library
        case "feed": self = .feed
        case "all": self = .all
        default: return nil
        }
    }

    var wire: String {
        switch self {
        case .library: "library"
        case .feed: "feed"
        case .all: "all"
        }
    }
}

extension Items {
    /// Every view the copy holds.
    ///
    /// Hydrate with `system.view` in the slice, or pin a view, to hold it. While a hydration is still filling the
    /// copy the answer holds the views that have arrived, and `completeness` says `.partial`. Throws
    /// `MarfaError.invalid` for a view whose settings this build cannot read.
    public func views() async throws -> Rows<SavedView> {
        try await holder.run { core in
            let views = try core.listViews()
            return Rows(try views.views.map(SavedView.init), completeness: views.completeness)
        }
    }

    /// `nil` where the copy does not hold the view.
    ///
    /// Throws `MarfaError.invalid` for a held item that is not a `system.view`, or a view whose settings this build
    /// cannot read.
    public func view(_ id: String) async throws -> SavedView? {
        try await holder.run { core in try core.view(id: id).map(SavedView.init) }
    }

    /// The items a view lists, in the order of one of its layouts, read from the copy alone.
    ///
    /// `layout` is a layout's id, and `nil` is the view's first layout. Items that tie on every sort key follow in
    /// ascending id order.
    ///
    /// Throws `MarfaError.invalid`, naming the reason, where the copy cannot answer the whole view: a type or tier
    /// the query lists that the slice does not hold, `beneath` without `parent-of` held whole, a `backref` in the
    /// filter, a revoked view, an item that is not a `system.view`, or a `layout` the view does not have. While a
    /// hydration is still filling the copy the list holds the items that have arrived, and `completeness` says
    /// `.partial`. Throws `MarfaError.notFound` with the code `not_held` for a view the copy does not hold; hydrate
    /// with `system.view` in the slice, or pin it.
    public func list(inView id: String, layout: String? = nil, limit: UInt32? = nil, offset: UInt32? = nil)
        async throws -> Rows<Item>
    {
        try await holder.run { core in
            try core.listInView(id: id, layout: layout, limit: limit, offset: offset).answer
        }
    }

    /// The groups of one of a view's layouts, with each group's count, in the order the layout gives.
    ///
    /// The groups its ``ViewGrouping/order`` names come first, in that order, then the others by ascending key with
    /// the `null` group last, and the groups in ``ViewGrouping/hidden`` are left out. A layout that groups nothing
    /// answers one `null` group of every item. When the layout charts a sum, each group carries it.
    ///
    /// Date groups follow the calendar of `timeZone`, or of the device's when it is `nil`. Throws as
    /// ``list(inView:layout:limit:offset:)`` does, and `MarfaError.invalid` for a group by `edge[<type>]` or
    /// `backref[<type>]` of an edge type the slice does not hold whole: pass it as an `edgeTypes` of `hydrate`.
    public func groups(inView id: String, layout: String, timeZone: TimeZone? = nil) async throws -> Rows<ViewGroup> {
        try await holder.run { core in
            let groups = try core.viewGroups(id: id, layout: layout, timeZone: timeZone?.identifier)
            return Rows(groups.groups, completeness: groups.completeness)
        }
    }
}

extension WorkingCopy {
    /// A full-text search narrowed to what the view lists; it throws as ``Items/list(inView:layout:limit:offset:)``
    /// throws.
    public func search(_ query: String, inView id: String, limit: Int = 20) async throws -> Rows<SearchHit> {
        try await holder.run { core in
            try core.searchInView(query: query, id: id, limit: UInt32(clamping: limit)).answer
        }
    }
}

extension Reading where Value == Rows<SavedView> {
    /// Every view the copy holds, as `items.views()` answers.
    public static var views: Reading {
        Reading(placeholder: .unread) { copy in try await copy.items.views() }
    }
}

extension Reading where Value == SavedView? {
    /// One view, `nil` while the copy does not hold it, as `items.view(_:)` answers.
    public static func view(_ id: String) -> Reading {
        Reading(placeholder: nil) { copy in try await copy.items.view(id) }
    }
}

extension Reading where Value == Rows<Item> {
    /// The items a view lists in one layout's order, as `items.list(inView:layout:limit:offset:)` answers them.
    ///
    /// The query reads again when an item enters or leaves the view, or changes in a way that moves it.
    public static func list(inView id: String, layout: String? = nil, limit: UInt32? = nil, offset: UInt32? = nil)
        -> Reading
    {
        Reading(placeholder: .unread) { copy in
            try await copy.items.list(inView: id, layout: layout, limit: limit, offset: offset)
        }
    }
}

extension Reading where Value == Rows<ViewGroup> {
    /// The groups of a view's layout with their counts, as `items.groups(inView:layout:timeZone:)` answers them.
    ///
    /// The query reads again when an item enters or leaves the view, or changes group.
    public static func groups(inView id: String, layout: String, timeZone: TimeZone? = nil) -> Reading {
        Reading(placeholder: .unread) { copy in
            try await copy.items.groups(inView: id, layout: layout, timeZone: timeZone)
        }
    }
}
