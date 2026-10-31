import Foundation
internal import MarfaCore

/// A `system.view`: a saved list of items, with the order and grouping every app shows them in.
///
/// It is not called `View`, which would be ambiguous with SwiftUI's in every file that imports both.
///
/// A view says which items to list in its ``ViewSettings/query``, in what order in its ``ViewSettings/sort`` and how
/// they group in its ``ViewSettings/group``. How an app draws them is the app's own. Read one with
/// ``Items/view(_:)``, its items with ``Items/list(inView:limit:offset:)`` and its groups with
/// ``Items/groups(inView:timeZone:)``. ``WorkingCopy/createView(_:idempotencyKey:)``,
/// ``WorkingCopy/changeView(_:_:baseVersion:idempotencyKey:)`` and ``WorkingCopy/deleteView(_:idempotencyKey:)``
/// write one.
public struct SavedView: Sendable, Hashable, Identifiable {
    public let id: String
    public let version: Int64
    /// `.revoked` is final: the view changes no more.
    public let state: ItemState
    public let settings: ViewSettings

    public init(id: String, version: Int64, state: ItemState = .active, settings: ViewSettings) {
        self.id = id
        self.version = version
        self.state = state
        self.settings = settings
    }

    init(_ core: MarfaCore.ViewRow) throws {
        id = core.id
        version = core.version
        state = ItemState(core.state)
        settings = try ViewSettings(JSONObject(core.settings), of: core.id)
    }
}

/// What a view lists, in what order, and how it groups.
public struct ViewSettings: Sendable, Hashable {
    public var title: String
    public var query: ViewQuery
    /// The keys the view sorts by, first key first; empty keeps the server's default order.
    public var sort: [ViewSort]
    /// `nil` groups nothing.
    public var group: ViewGrouping?

    public init(title: String, query: ViewQuery = ViewQuery(), sort: [ViewSort] = [], group: ViewGrouping? = nil) {
        self.title = title
        self.query = query
        self.sort = sort
        self.group = group
    }

    init(_ core: JSONObject, of view: String) throws {
        let reader = ViewReader(view: view)
        title = try reader.string(core["title"], "title")
        query = try ViewQuery(reader.optionalObject(core["query"], "query"), reader)
        sort =
            try reader.optionalArray(core["sort"], "sort")?.enumerated().map { index, sort in
                try ViewSort(reader.object(sort, "sort.\(index)"), reader, path: "sort.\(index)")
            } ?? []
        group = try reader.optionalObject(core["group"], "group").map { try ViewGrouping($0, reader, path: "group") }
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
    /// An expression in the server's listing grammar, which takes the `status_group` term as ``ListFilters`` says:
    /// `status_group neq "completed" AND status_group neq "canceled"` holds the open items.
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

/// One key a view sorts by.
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

/// How a view groups its items.
public struct ViewGrouping: Sendable, Hashable {
    /// A field, or `edge[<type>]` or `backref[<type>]` for the item an edge of that type joins.
    public var by: String
    /// For a date field, the span each group covers. `nil` groups by the value.
    public var bucket: Bucket?
    /// The keys whose groups come first, in this order.
    public var order: [JSONValue]
    /// The keys whose groups the view leaves out.
    ///
    /// The view still lists their items.
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
            return Rows(try views.views.map(SavedView.init), completeness: Completeness(views.completeness))
        }
    }

    /// `nil` where the copy does not hold the view.
    ///
    /// Throws `MarfaError.invalid` for a held item that is not a `system.view`, or a view whose settings this build
    /// cannot read.
    public func view(_ id: String) async throws -> SavedView? {
        try await holder.run { core in try core.view(id: id).map(SavedView.init) }
    }

    /// The items a view lists, in the order of its ``ViewSettings/sort``, read from the copy alone.
    ///
    /// Items that tie on every sort key follow in ascending id order.
    ///
    /// Throws `MarfaError.invalid`, naming the reason, where the copy cannot answer the whole view: a type or tier
    /// the query lists that the slice does not hold, `beneath` without `parent-of` held whole, a `backref` in the
    /// filter of an edge type the slice does not hold whole, a revoked view, or an item that is not a `system.view`. While a
    /// hydration is still filling the copy the list holds the items that have arrived, and `completeness` says
    /// `.partial`. Throws `MarfaError.notFound` with the code `not_held` for a view the copy does not hold; hydrate
    /// with `system.view` in the slice, or pin it.
    public func list(inView id: String, limit: UInt32? = nil, offset: UInt32? = nil) async throws -> Rows<Item> {
        try await holder.run { core in
            try core.listInView(id: id, limit: limit, offset: offset).answer
        }
    }

    /// The groups of a view, with each group's count, in the order the view gives.
    ///
    /// The groups its ``ViewGrouping/order`` names come first, in that order, then the others by ascending key with
    /// the `null` group last, and the groups in ``ViewGrouping/hidden`` are left out. A view that groups nothing
    /// answers one `null` group of every item.
    ///
    /// Date groups follow the calendar of `timeZone`, or of the device's when it is `nil`. Throws as
    /// ``list(inView:limit:offset:)`` does, and `MarfaError.invalid` for a group by `edge[<type>]` or
    /// `backref[<type>]` of an edge type the slice does not hold whole: pass it as an `edgeTypes` of `hydrate`.
    public func groups(inView id: String, timeZone: TimeZone? = nil) async throws -> Rows<ViewGroup> {
        try await holder.run { core in
            let groups = try core.viewGroups(id: id, timeZone: timeZone?.identifier)
            return Rows(groups.groups.map(ViewGroup.init), completeness: Completeness(groups.completeness))
        }
    }
}

extension WorkingCopy {
    /// A full-text search narrowed to what the view lists; it throws as ``Items/list(inView:limit:offset:)``
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
    /// The items a view lists in its order, as `items.list(inView:limit:offset:)` answers them.
    ///
    /// The query reads again when an item enters or leaves the view, or changes in a way that moves it.
    public static func list(inView id: String, limit: UInt32? = nil, offset: UInt32? = nil) -> Reading {
        Reading(placeholder: .unread) { copy in
            try await copy.items.list(inView: id, limit: limit, offset: offset)
        }
    }
}

extension Reading where Value == Rows<ViewGroup> {
    /// The groups of a view with their counts, as `items.groups(inView:timeZone:)` answers them.
    ///
    /// The query reads again when an item enters or leaves the view, or changes group.
    public static func groups(inView id: String, timeZone: TimeZone? = nil) -> Reading {
        Reading(placeholder: .unread) { copy in
            try await copy.items.groups(inView: id, timeZone: timeZone)
        }
    }
}
