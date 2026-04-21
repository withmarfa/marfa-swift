import Foundation

/// Items API namespace. Provides CRUD, transitions, versions, and stats.
public struct ItemsNamespace: Sendable {

    let transport: any Transport
    let defaultConflictStrategy: ConflictStrategy
    let localStore: LocalStore?
    let mutationQueue: MutationQueue?

    /// Creates a new item.
    ///
    /// In synced mode the SDK stamps a client-minted UUIDv7 into `input.id`
    /// before the local write and the mutation-queue enqueue, so the replay
    /// payload travels with the same id the local store knows about. Without
    /// the stamp, the server would mint its own id on replay, triggering
    /// `SyncEngine.replayRecord`'s reconcile path — which `purgeItem`s the
    /// original local row and leaves any app view holding that id pointing at
    /// a phantom. Callers that already supply `input.id` are unaffected.
    public func create(_ input: CreateItemInput) async throws -> Item {
        if let store = localStore {
            var stamped = input
            if stamped.id == nil {
                stamped.id = UUIDv7.generateString()
            }
            let item = try await store.createItem(stamped)
            try await mutationQueue?.enqueueCreateItem(stamped, localId: item.id)
            return item
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
    /// In local mode the update is applied directly (no conflict resolution
    /// needed). In synced mode the local store is updated immediately and the
    /// mutation enqueued for replay; the per-call conflict strategy is
    /// captured with the queued mutation so replay can apply it on a 409
    /// (note: the `.callback` resolver closure is not persisted — on replay,
    /// `.callback` degrades to `.auto`).
    public func update(
        id: String,
        properties: [String: JSONValue],
        options: UpdateOptions? = nil
    ) async throws -> Item {
        if let store = localStore {
            let item = try await store.updateItem(
                id: id,
                properties: properties,
                library: options?.library
            )
            try await mutationQueue?.enqueueUpdateItem(
                id: id,
                properties: properties,
                version: options?.version,
                conflict: options?.conflict ?? defaultConflictStrategy,
                library: options?.library
            )
            return item
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
            resolver: options?.resolve,
            library: options?.library
        )
    }

    /// Soft-deletes an item by transitioning it to the `trashed` state.
    ///
    /// The item remains retrievable (``restore(id:)`` reverts it) and continues
    /// to occupy its id. Use ``purge(id:)`` to remove a trashed item for good.
    ///
    /// - Parameter id: The item id.
    public func delete(id: String) async throws {
        if let store = localStore {
            try await store.trashItem(id: id)
            try await mutationQueue?.enqueueDeleteItem(id: id)
            return
        }
        let _: EmptyResponse = try await transport.request(
            method: .delete, path: "/items/\(id)", body: nil, query: nil
        )
    }

    /// Restores a trashed item.
    public func restore(id: String) async throws -> Item {
        if let store = localStore {
            let item = try await store.restoreItem(id: id)
            try await mutationQueue?.enqueueRestoreItem(id: id)
            return item
        }
        let response: ItemResponse = try await transport.request(
            method: .post, path: "/items/\(id)/restore", body: nil, query: nil
        )
        return response.item
    }

    /// Transitions an item to a new lifecycle state.
    public func transition(id: String, to state: String) async throws -> Item {
        if let store = localStore {
            let item = try await store.transitionItem(id: id, to: state)
            try await mutationQueue?.enqueueTransitionItem(id: id, to: state)
            return item
        }
        let response: ItemResponse = try await transport.request(
            method: .post, path: "/items/\(id)/transition",
            body: TransitionBody(state: state), query: nil
        )
        return response.item
    }

    /// Lists an item's version history.
    ///
    /// Version history is server-owned — the local store only tracks the
    /// current revision. Mode routing splits on `mutationQueue`, not
    /// `localStore`, because both pure-local and synced clients populate a
    /// local store:
    ///
    /// - **Pure-local** (`mutationQueue == nil`) — no remote to call; returns
    ///   a single-element array wrapping the current item.
    /// - **Synced** (`mutationQueue != nil`) — issues `GET /items/:id/versions`
    ///   and returns the server's history, same as the network-only path.
    public func versions(id: String) async throws -> [Version] {
        if let store = localStore, mutationQueue == nil {
            let item = try await store.fetchItem(id: id)
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

    /// Permanently removes a trashed item. Irreversible.
    ///
    /// The item must already be in the `trashed` state — call ``delete(id:)``
    /// first if needed. Requires the `admin:purge` scope on the API key.
    ///
    /// - Parameter id: The item id.
    public func purge(id: String) async throws {
        if let store = localStore {
            try await store.purgeItem(id: id)
            try await mutationQueue?.enqueuePurgeItem(id: id)
            return
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
