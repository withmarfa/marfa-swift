import Foundation

/// Items API namespace. Provides CRUD, transitions, versions, and stats.
public struct ItemsNamespace: Sendable {

    let transport: any Transport
    let defaultConflictStrategy: ConflictStrategy

    /// Creates a new item.
    public func create(_ input: CreateItemInput) async throws -> Item {
        let response: ItemResponse = try await transport.request(
            method: .post, path: "/items", body: input, query: nil
        )
        return response.item
    }

    /// Fetches a single item by ID.
    public func get(id: String) async throws -> Item {
        let response: ItemResponse = try await transport.request(
            method: .get, path: "/items/\(id)", body: nil, query: nil
        )
        return response.item
    }

    /// Lists items with optional filtering, sorting, and pagination.
    public func list(filters: ListFilters? = nil) async throws -> PaginatedResult<Item> {
        try await transport.request(
            method: .get, path: "/items", body: nil,
            query: filters?.toQueryParams()
        )
    }

    /// Lists items with metadata included.
    public func listWithMetadata(filters: ListFilters? = nil) async throws -> PaginatedResult<ItemWithMetadata> {
        var params = filters?.toQueryParams() ?? []
        params.append(("include", "metadata"))
        return try await transport.request(
            method: .get, path: "/items", body: nil, query: params
        )
    }

    /// Updates an item's properties with conflict resolution.
    ///
    /// If no version is provided in `options`, the current version is fetched first.
    /// Conflict resolution uses the strategy from `options`, falling back to the
    /// client's default strategy.
    public func update(
        id: String,
        properties: [String: JSONValue],
        options: UpdateOptions? = nil
    ) async throws -> Item {
        let resolvedVersion: Int
        if let v = options?.version {
            resolvedVersion = v
        } else {
            resolvedVersion = try await get(id: id).version
        }

        let strategy = options?.conflict ?? defaultConflictStrategy

        return try await handleConflictUpdate(
            transport: transport,
            itemId: id,
            clientPatch: properties,
            version: resolvedVersion,
            strategy: strategy,
            resolver: options?.resolve
        )
    }

    /// Soft-deletes an item (transitions to trashed).
    public func delete(id: String) async throws {
        let _: EmptyResponse = try await transport.request(
            method: .delete, path: "/items/\(id)", body: nil, query: nil
        )
    }

    /// Restores a trashed item.
    public func restore(id: String) async throws -> Item {
        let response: ItemResponse = try await transport.request(
            method: .post, path: "/items/\(id)/restore", body: nil, query: nil
        )
        return response.item
    }

    /// Transitions an item to a new lifecycle state.
    public func transition(id: String, to state: String) async throws -> Item {
        let response: ItemResponse = try await transport.request(
            method: .post, path: "/items/\(id)/transition",
            body: TransitionBody(state: state), query: nil
        )
        return response.item
    }

    /// Lists an item's version history.
    public func versions(id: String) async throws -> [Version] {
        let response: VersionsResponse = try await transport.request(
            method: .get, path: "/items/\(id)/versions", body: nil, query: nil
        )
        return response.versions
    }

    /// Returns item counts grouped by state.
    public func stats() async throws -> [String: Int] {
        try await transport.request(
            method: .get, path: "/items/stats", body: nil, query: nil
        )
    }

    /// Permanently deletes a trashed item (admin only).
    public func purge(id: String) async throws {
        let _: EmptyResponse = try await transport.request(
            method: .delete, path: "/items/\(id)/purge", body: nil, query: nil
        )
    }

    // MARK: - Edge-related reads

    /// Lists outbound edges from the item — edges where this item is the source.
    /// Filter by `edgeType` to narrow to a single relationship (e.g. `"about"`).
    public func edges(
        id: String,
        edgeType: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> PaginatedResult<Edge> {
        var query: [(String, String)] = []
        if let edgeType { query.append(("edge_type", edgeType)) }
        if let cursor { query.append(("cursor", cursor)) }
        if let limit { query.append(("limit", String(limit))) }
        return try await transport.request(
            method: .get, path: "/items/\(id)/edges", body: nil,
            query: query.isEmpty ? nil : query
        )
    }

    /// Lists inbound edges pointing at the item — edges where this item is the target.
    /// Use for "who references me?" queries (e.g. list all `in-thread` edges
    /// whose target is this thread to enumerate its members).
    public func backrefs(
        id: String,
        edgeType: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> PaginatedResult<Edge> {
        var query: [(String, String)] = []
        if let edgeType { query.append(("edge_type", edgeType)) }
        if let cursor { query.append(("cursor", cursor)) }
        if let limit { query.append(("limit", String(limit))) }
        return try await transport.request(
            method: .get, path: "/items/\(id)/backrefs", body: nil,
            query: query.isEmpty ? nil : query
        )
    }

    /// Returns an `AsyncSequence` that iterates through all items matching the filters,
    /// automatically fetching subsequent pages.
    public func all(filters: ListFilters? = nil) -> PaginatedSequence<Item> {
        PaginatedSequence { cursor in
            var f = filters ?? ListFilters()
            f.cursor = cursor
            if f.limit == nil { f.limit = 200 }
            return try await self.list(filters: f)
        }
    }

    /// Returns an `AsyncSequence` that iterates through all items with metadata,
    /// automatically fetching subsequent pages.
    public func allWithMetadata(filters: ListFilters? = nil) -> PaginatedSequence<ItemWithMetadata> {
        PaginatedSequence { cursor in
            var f = filters ?? ListFilters()
            f.cursor = cursor
            if f.limit == nil { f.limit = 200 }
            return try await self.listWithMetadata(filters: f)
        }
    }
}
