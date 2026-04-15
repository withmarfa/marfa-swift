import Foundation

/// Items API namespace. Provides CRUD, transitions, versions, and stats.
public struct ItemsNamespace: Sendable {

    let transport: any Transport
    let defaultConflictStrategy: ConflictStrategy
    let localStore: LocalStore?

    /// Creates a new item.
    public func create(_ input: CreateItemInput) async throws -> Item {
        if let store = localStore {
            return try await store.createItem(input)
        }
        let response: ItemResponse = try await transport.request(
            method: .post, path: "/items", body: input, query: nil
        )
        return response.item
    }

    /// Fetches a single item by ID.
    public func get(id: String) async throws -> Item {
        if let store = localStore {
            return try await store.fetchItem(id: id)
        }
        let response: ItemResponse = try await transport.request(
            method: .get, path: "/items/\(id)", body: nil, query: nil
        )
        return response.item
    }

    /// Lists items with optional filtering, sorting, and pagination.
    public func list(filters: ListFilters? = nil) async throws -> PaginatedResult<Item> {
        if let store = localStore {
            return try await store.fetchItems(filters: filters)
        }
        return try await transport.request(
            method: .get, path: "/items", body: nil,
            query: filters?.toQueryParams()
        )
    }

    /// Lists items with metadata included.
    public func listWithMetadata(filters: ListFilters? = nil) async throws -> PaginatedResult<ItemWithMetadata> {
        if let store = localStore {
            let result = try await store.fetchItems(filters: filters)
            let pairs = try await withThrowingTaskGroup(of: ItemWithMetadata.self) { group in
                for item in result.data {
                    group.addTask {
                        let metadata = try await store.fetchMetadata(itemId: item.id)
                        return ItemWithMetadata(item: item, metadata: metadata)
                    }
                }
                var collected: [ItemWithMetadata] = []
                for try await pair in group { collected.append(pair) }
                return collected
            }
            return PaginatedResult(data: pairs, cursor: nil, hasMore: false)
        }
        var params = filters?.toQueryParams() ?? []
        params.append(("include", "metadata"))
        return try await transport.request(
            method: .get, path: "/items", body: nil, query: params
        )
    }

    /// Updates an item's properties with conflict resolution.
    ///
    /// In local mode the update is applied directly (no conflict resolution needed).
    /// In network mode the client's default conflict strategy applies.
    public func update(
        id: String,
        properties: [String: JSONValue],
        options: UpdateOptions? = nil
    ) async throws -> Item {
        if let store = localStore {
            return try await store.updateItem(id: id, properties: properties)
        }
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
        if let store = localStore {
            return try await store.trashItem(id: id)
        }
        let _: EmptyResponse = try await transport.request(
            method: .delete, path: "/items/\(id)", body: nil, query: nil
        )
    }

    /// Restores a trashed item.
    public func restore(id: String) async throws -> Item {
        if let store = localStore {
            return try await store.restoreItem(id: id)
        }
        let response: ItemResponse = try await transport.request(
            method: .post, path: "/items/\(id)/restore", body: nil, query: nil
        )
        return response.item
    }

    /// Transitions an item to a new lifecycle state.
    public func transition(id: String, to state: String) async throws -> Item {
        if let store = localStore {
            return try await store.transitionItem(id: id, to: state)
        }
        let response: ItemResponse = try await transport.request(
            method: .post, path: "/items/\(id)/transition",
            body: TransitionBody(state: state), query: nil
        )
        return response.item
    }

    /// Lists an item's version history.
    ///
    /// Not supported in pure-local mode (always returns the current single version).
    public func versions(id: String) async throws -> [Version] {
        if localStore != nil {
            let item = try await get(id: id)
            return [Version(
                createdAt: item.createdAt,
                id: item.id,
                itemId: item.id,
                properties: item.properties,
                version: item.version
            )]
        }
        let response: VersionsResponse = try await transport.request(
            method: .get, path: "/items/\(id)/versions", body: nil, query: nil
        )
        return response.versions
    }

    /// Returns item counts grouped by state.
    public func stats() async throws -> [String: Int] {
        if let store = localStore {
            return try await store.itemStats()
        }
        return try await transport.request(
            method: .get, path: "/items/stats", body: nil, query: nil
        )
    }

    /// Permanently deletes a trashed item (admin only).
    public func purge(id: String) async throws {
        if let store = localStore {
            return try await store.purgeItem(id: id)
        }
        let _: EmptyResponse = try await transport.request(
            method: .delete, path: "/items/\(id)/purge", body: nil, query: nil
        )
    }

    // MARK: - Edge-related reads

    /// Lists outbound edges from the item — edges where this item is the source.
    public func edges(
        id: String,
        edgeType: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> PaginatedResult<Edge> {
        if let store = localStore {
            return try await store.fetchEdgesFromSource(
                sourceId: id, edgeType: edgeType, limit: limit
            )
        }
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
    public func backrefs(
        id: String,
        edgeType: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> PaginatedResult<Edge> {
        if let store = localStore {
            return try await store.fetchEdgesToTarget(
                targetId: id, edgeType: edgeType, limit: limit
            )
        }
        var query: [(String, String)] = []
        if let edgeType { query.append(("edge_type", edgeType)) }
        if let cursor { query.append(("cursor", cursor)) }
        if let limit { query.append(("limit", String(limit))) }
        return try await transport.request(
            method: .get, path: "/items/\(id)/backrefs", body: nil,
            query: query.isEmpty ? nil : query
        )
    }

    /// Returns an `AsyncSequence` that iterates through all items matching the filters.
    public func all(filters: ListFilters? = nil) -> PaginatedSequence<Item> {
        PaginatedSequence { cursor in
            var f = filters ?? ListFilters()
            f.cursor = cursor
            if f.limit == nil { f.limit = 200 }
            return try await self.list(filters: f)
        }
    }

    /// Returns an `AsyncSequence` that iterates through all items with metadata.
    public func allWithMetadata(filters: ListFilters? = nil) -> PaginatedSequence<ItemWithMetadata> {
        PaginatedSequence { cursor in
            var f = filters ?? ListFilters()
            f.cursor = cursor
            if f.limit == nil { f.limit = 200 }
            return try await self.listWithMetadata(filters: f)
        }
    }
}
