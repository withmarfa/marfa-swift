import Foundation

/// Filters for listing items.
///
/// `parent_id` / `thread_id` are gone — items no longer carry those columns.
/// Query relationships via the edge filters: pass `edge: ["parent-of": parentId]`
/// to list items whose own outbound `parent-of` points at `parentId`, or
/// `backref: ["in-thread": threadId]` to list members of the thread.
public struct ListFilters: Sendable {
    public var type: String?
    public var state: ItemState?
    public var source: String?
    public var tier: TierFilter?
    public var tags: [String]?
    public var filter: String?
    public var sort: SortField?
    public var direction: SortDirection?
    public var since: String?
    public var until: String?
    public var limit: Int?
    public var cursor: String?
    /// Outbound edge filter — `[edgeType: targetId]`. Restricts to items that
    /// have at least one outbound edge of `edgeType` pointing at `targetId`.
    /// Serializes as `?edge[<type>]=<targetId>`.
    public var edge: [String: String]?
    /// Inbound edge filter — `[edgeType: sourceId]`. Restricts to items that
    /// are the target of at least one edge of `edgeType` from `sourceId`.
    /// Serializes as `?backref[<type>]=<sourceId>`.
    public var backref: [String: String]?

    public init(
        type: String? = nil,
        state: ItemState? = nil,
        source: String? = nil,
        tier: TierFilter? = nil,
        tags: [String]? = nil,
        filter: String? = nil,
        sort: SortField? = nil,
        direction: SortDirection? = nil,
        since: String? = nil,
        until: String? = nil,
        limit: Int? = nil,
        cursor: String? = nil,
        edge: [String: String]? = nil,
        backref: [String: String]? = nil
    ) {
        self.type = type
        self.state = state
        self.source = source
        self.tier = tier
        self.tags = tags
        self.filter = filter
        self.sort = sort
        self.direction = direction
        self.since = since
        self.until = until
        self.limit = limit
        self.cursor = cursor
        self.edge = edge
        self.backref = backref
    }

    /// Converts to query parameter pairs for the HTTP transport.
    func toQueryParams() -> [(String, String)] {
        var params: [(String, String)] = []
        if let type { params.append(("type", type)) }
        if let state { params.append(("state", state.rawValue)) }
        if let source { params.append(("source", source)) }
        if let tier { params.append(("tier", tier.rawValue)) }
        if let tags, !tags.isEmpty { params.append(("tags", tags.joined(separator: ","))) }
        if let filter { params.append(("filter", filter)) }
        if let sort { params.append(("sort", sort.rawValue)) }
        if let direction { params.append(("direction", direction.rawValue)) }
        if let since { params.append(("since", since)) }
        if let until { params.append(("until", until)) }
        if let limit { params.append(("limit", String(limit))) }
        if let cursor { params.append(("cursor", cursor)) }
        if let edge {
            // Deterministic key order for stable request URLs in tests.
            for (key, value) in edge.sorted(by: { $0.key < $1.key }) {
                params.append(("edge[\(key)]", value))
            }
        }
        if let backref {
            for (key, value) in backref.sorted(by: { $0.key < $1.key }) {
                params.append(("backref[\(key)]", value))
            }
        }
        return params
    }
}

/// Filter for `GET /items?tier=...` and `GET /search?tier=...`.
///
/// Omitting the filter (`tier: nil`) returns items of any tier. Use
/// `.library` to narrow to curated items or `.feed` to narrow to
/// high-volume capture. There is no `.all` synonym — `nil` already
/// expresses that.
public enum TierFilter: String, Sendable, Hashable, Codable {
    case library
    case feed
}

/// Fields available for sorting.
public enum SortField: String, Sendable {
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case timestamp
}

/// Sort direction.
public enum SortDirection: String, Sendable {
    case ascending = "asc"
    case descending = "desc"
}

/// Filters for search queries.
///
/// `system.*` items are excluded from search by the server's default
/// rules — to surface them, request the type explicitly via
/// `type: "system.device"` (etc.).
public struct SearchFilters: Sendable {
    public var type: String?
    public var state: ItemState?
    public var tier: TierFilter?
    /// Items must have ALL specified tags. Mirrors `ListFilters.tags` and
    /// `/items?tags=`. Comma-joined when serialized.
    public var tags: [String]?
    public var filter: String?
    public var limit: Int?

    public init(
        type: String? = nil,
        state: ItemState? = nil,
        tier: TierFilter? = nil,
        tags: [String]? = nil,
        filter: String? = nil,
        limit: Int? = nil
    ) {
        self.type = type
        self.state = state
        self.tier = tier
        self.tags = tags
        self.filter = filter
        self.limit = limit
    }

    func toQueryParams(query: String) -> [(String, String)] {
        var params: [(String, String)] = [("q", query)]
        if let type { params.append(("type", type)) }
        if let state { params.append(("state", state.rawValue)) }
        if let tier { params.append(("tier", tier.rawValue)) }
        if let tags, !tags.isEmpty {
            params.append(("tags", tags.joined(separator: ",")))
        }
        if let filter { params.append(("filter", filter)) }
        if let limit { params.append(("limit", String(limit))) }
        return params
    }
}

/// Input for metadata set/merge operations.
///
/// Metadata is tags-only — the `about` references field moved to first-class
/// `about` edges. Create an `about` edge via `client.edges.create(...)`.
public struct MetadataInput: Codable, Sendable {
    public var tags: [String]?

    public init(tags: [String]? = nil) {
        self.tags = tags
    }
}

/// Body for POST /items/:id/tags.
struct AddTagsBody: Codable, Sendable {
    let tags: [String]
}
