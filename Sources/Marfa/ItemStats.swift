import Foundation

/// The item property the server groups counts by.
public enum ItemStatsGrouping: String, Sendable, Hashable, CaseIterable {
    /// The item's lifecycle state.
    case state
    /// The item's type identifier.
    case type
    /// The item's source code.
    case source
}

/// Narrows which items the server counts.
///
/// Time bounds accept an RFC 3339 timestamp or a date in `YYYY-MM-DD` form, which means midnight in UTC.
/// Use ``ItemDate/instant(_:)`` to convert a `Date`. Occurrence bounds use the item's `occurred_at` or, when
/// absent, its `created_at`.
public struct ItemStatsFilters: Sendable, Hashable {
    /// Up to ten type identifiers or wildcard patterns, each including its subtypes.
    ///
    /// Use `nil` to omit the type filter. The server refuses an empty set.
    public var types: Set<String>?
    /// The lifecycle states to count.
    ///
    /// Use `nil` to count every state, including the bin. The server refuses an empty set.
    public var states: Set<ItemState>?
    /// The tier to count. `nil` counts both tiers.
    public var tier: Tier?
    /// Exclusive lower bound on the item's occurrence time.
    public var occurredAfter: String?
    /// Exclusive upper bound on the item's occurrence time.
    public var occurredBefore: String?
    /// The source code each item must carry.
    public var source: String?
    /// Inclusive lower bound on the time the item was last changed.
    public var updatedAfter: String?
    /// Exclusive upper bound on the time the item was last changed.
    public var updatedBefore: String?
    /// An expression in the server's listing grammar.
    ///
    /// An `edge` or `backref` term requires read access to the edge type it names.
    public var filter: String?
    /// The ID of an item to count along with its readable descendants.
    ///
    /// Requires read access to `parent-of` edges.
    public var beneath: String?
    /// Whether to count readable hidden items.
    ///
    /// An exact hidden type filter also opts in to that type.
    public var includeHidden: Bool

    /// Creates a set of filters for the server's counts.
    public init(
        types: Set<String>? = nil, states: Set<ItemState>? = nil, tier: Tier? = nil,
        occurredAfter: String? = nil, occurredBefore: String? = nil, source: String? = nil, updatedAfter: String? = nil,
        updatedBefore: String? = nil, filter: String? = nil, beneath: String? = nil, includeHidden: Bool = false
    ) {
        self.types = types
        self.states = states
        self.tier = tier
        self.occurredAfter = occurredAfter
        self.occurredBefore = occurredBefore
        self.source = source
        self.updatedAfter = updatedAfter
        self.updatedBefore = updatedBefore
        self.filter = filter
        self.beneath = beneath
        self.includeHidden = includeHidden
    }
}

/// One group of ``Server/itemStats(by:filters:timeout:)``: its state, type identifier, or source code, and how many
/// items it holds.
public struct ItemStatsGroup: Sendable, Hashable {
    /// The lifecycle state, type identifier, or source code, exactly as the server stored it.
    public let key: String
    /// How many matching items the group holds.
    public let count: Int64

    /// Creates a group with its key and count.
    public init(key: String, count: Int64) {
        self.key = key
        self.count = count
    }
}

extension Server {
    /// Counts the readable items matching `filters`, one ``ItemStatsGroup`` per lifecycle state, type identifier, or
    /// source code, ordered by the key's UTF-8 bytes.
    ///
    /// Keys are compared byte for byte, so two source codes that differ only in Unicode normalization stay separate
    /// groups. Empty groups are omitted. An app needs read access to at least one item type, such as `core.note:read`.
    /// The server applies the credential's reach to the counts and to type and relationship filters.
    public func itemStats(
        by grouping: ItemStatsGrouping = .state, filters: ItemStatsFilters = .init(),
        timeout: Duration = Server.defaultTimeout
    ) async throws(MarfaError) -> [ItemStatsGroup] {
        let tier: String? =
            switch filters.tier {
            case .library: "library"
            case .feed: "feed"
            case nil: nil
            }
        let fields: [(String, String?)] = [
            ("by", grouping.rawValue),
            ("type", filters.types?.sorted().joined(separator: ",")),
            ("state", filters.states?.map(\.statsQueryValue).sorted().joined(separator: ",")),
            ("tier", tier),
            ("source", filters.source),
            ("occurred_after", filters.occurredAfter),
            ("occurred_before", filters.occurredBefore),
            ("updated_after", filters.updatedAfter),
            ("updated_before", filters.updatedBefore),
            ("filter", filters.filter),
            ("beneath", filters.beneath),
            ("include", filters.includeHidden ? "hidden" : nil),
        ]
        let query = fields.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        let data = try await send("GET", "/items/stats", query: query, timeout: timeout)
        // JSONDecoder keys a dictionary by String, which merges canonically equivalent keys, so the body is read
        // through NSDictionary, whose keys compare literally.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? NSDictionary else {
            throw .decoding(message: "\(origin) answered in a form this build cannot read")
        }
        var counts: [ItemStatsGroup] = []
        for (key, value) in object {
            guard let key = key as? NSString, let value = value as? NSNumber, NSNumber(value: value.int64Value) == value
            else { throw .decoding(message: "\(origin) answered in a form this build cannot read") }
            counts.append(ItemStatsGroup(key: key as String, count: value.int64Value))
        }
        return counts.sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }
    }
}

extension ItemState {
    fileprivate var statsQueryValue: String {
        switch self {
        case .active: "active"
        case .archived: "archived"
        case .trashed: "trashed"
        case .revoked: "revoked"
        }
    }
}
