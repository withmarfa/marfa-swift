import Foundation

/// Filters for listing items.
public struct ListFilters: Sendable {
    public var type: String?
    public var state: ItemState?
    public var source: String?
    public var parentId: String?
    public var threadId: String?
    public var rootOnly: Bool?
    public var tags: [String]?
    public var filter: String?
    public var sort: SortField?
    public var direction: SortDirection?
    public var since: String?
    public var until: String?
    public var limit: Int?
    public var cursor: String?

    public init(
        type: String? = nil,
        state: ItemState? = nil,
        source: String? = nil,
        parentId: String? = nil,
        threadId: String? = nil,
        rootOnly: Bool? = nil,
        tags: [String]? = nil,
        filter: String? = nil,
        sort: SortField? = nil,
        direction: SortDirection? = nil,
        since: String? = nil,
        until: String? = nil,
        limit: Int? = nil,
        cursor: String? = nil
    ) {
        self.type = type
        self.state = state
        self.source = source
        self.parentId = parentId
        self.threadId = threadId
        self.rootOnly = rootOnly
        self.tags = tags
        self.filter = filter
        self.sort = sort
        self.direction = direction
        self.since = since
        self.until = until
        self.limit = limit
        self.cursor = cursor
    }

    /// Converts to query parameter pairs for the HTTP transport.
    func toQueryParams() -> [(String, String)] {
        var params: [(String, String)] = []
        if let type { params.append(("type", type)) }
        if let state { params.append(("state", state.rawValue)) }
        if let source { params.append(("source", source)) }
        if let parentId { params.append(("parent_id", parentId)) }
        if let threadId { params.append(("thread_id", threadId)) }
        if let rootOnly { params.append(("root_only", rootOnly ? "true" : "false")) }
        if let tags, !tags.isEmpty { params.append(("tags", tags.joined(separator: ","))) }
        if let filter { params.append(("filter", filter)) }
        if let sort { params.append(("sort", sort.rawValue)) }
        if let direction { params.append(("direction", direction.rawValue)) }
        if let since { params.append(("since", since)) }
        if let until { params.append(("until", until)) }
        if let limit { params.append(("limit", String(limit))) }
        if let cursor { params.append(("cursor", cursor)) }
        return params
    }
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
public struct SearchFilters: Sendable {
    public var type: String?
    public var state: ItemState?
    public var filter: String?
    public var limit: Int?

    public init(
        type: String? = nil,
        state: ItemState? = nil,
        filter: String? = nil,
        limit: Int? = nil
    ) {
        self.type = type
        self.state = state
        self.filter = filter
        self.limit = limit
    }

    func toQueryParams(query: String) -> [(String, String)] {
        var params: [(String, String)] = [("q", query)]
        if let type { params.append(("type", type)) }
        if let state { params.append(("state", state.rawValue)) }
        if let filter { params.append(("filter", filter)) }
        if let limit { params.append(("limit", String(limit))) }
        return params
    }
}
