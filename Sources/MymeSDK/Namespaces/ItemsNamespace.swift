import Foundation

/// Items API namespace. Provides CRUD, transitions, versions, and stats.
public struct ItemsNamespace: Sendable {

    let transport: any Transport
    let defaultConflictStrategy: ConflictStrategy
    let localStore: LocalStore?
    let mutationQueue: MutationQueue?
    /// Base API URL — used by ``createWithAttachments(_:)`` to construct
    /// a sibling ``BlobsNamespace`` for the upload step. Optional because
    /// pure-local clients still build an `ItemsNamespace` and have no
    /// server URL.
    let apiBaseURL: URL?

    /// Designated init. `apiBaseURL` is optional with a `nil` default so
    /// existing call sites (tests, pure-local factories) don't need to
    /// be retrofitted — only ``createWithAttachments(_:)`` needs it.
    init(
        transport: any Transport,
        defaultConflictStrategy: ConflictStrategy,
        localStore: LocalStore? = nil,
        mutationQueue: MutationQueue? = nil,
        apiBaseURL: URL? = nil
    ) {
        self.transport = transport
        self.defaultConflictStrategy = defaultConflictStrategy
        self.localStore = localStore
        self.mutationQueue = mutationQueue
        self.apiBaseURL = apiBaseURL
    }

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
                tier: options?.tier
            )
            try await mutationQueue?.enqueueUpdateItem(
                id: id,
                properties: properties,
                version: options?.version,
                conflict: options?.conflict ?? defaultConflictStrategy,
                tier: options?.tier,
                sourceId: options?.sourceId
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
            tier: options?.tier,
            sourceId: options?.sourceId
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
    public func transition(id: String, to state: ItemState) async throws -> Item {
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

    // MARK: - Bulk

    /// Creates or upserts many items in one call (admin-only).
    ///
    /// Pure-local mode iterates the items through ``LocalStore/createItem(_:)``
    /// and returns best-effort per-item outcomes — no dedup on
    /// `(source, source_id)` at the local layer because local stores
    /// don't carry that uniqueness constraint. Synced mode enqueues
    /// the full input as a single ``MutationKind/bulk`` record; replay
    /// POSTs verbatim. Network-only mode round-trips the server
    /// response straight through.
    public func bulk(_ input: BulkInput) async throws -> BulkResult {
        if let store = localStore {
            var created = 0
            var errored = 0
            var results: [BulkResultEntry] = []
            results.reserveCapacity(input.items.count)

            for (index, raw) in input.items.enumerated() {
                var stamped = CreateItemInput(
                    type: raw.type,
                    properties: raw.properties ?? [:],
                    id: raw.id,
                    state: raw.state,
                    timestamp: raw.timestamp,
                    source: raw.source,
                    sourceId: raw.sourceId,
                    device: raw.device,
                    tier: raw.tier,
                    captureLatitude: nil,
                    captureLongitude: nil,
                    tags: raw.tags,
                    edges: nil
                )
                if stamped.id == nil { stamped.id = UUIDv7.generateString() }
                do {
                    let item = try await store.createItem(stamped)
                    results.append(BulkResultEntry(
                        index: index, outcome: .created, id: item.id,
                        reason: nil, error: nil
                    ))
                    created += 1
                } catch {
                    results.append(BulkResultEntry(
                        index: index, outcome: .errored, id: nil, reason: nil,
                        error: BulkResultError(
                            code: "local_error",
                            message: String(describing: error)
                        )
                    ))
                    errored += 1
                }
            }

            try await mutationQueue?.enqueueBulk(input)

            return BulkResult(
                counts: BulkResultCounts(
                    created: created, updated: 0, skipped: 0, errored: errored
                ),
                results: results,
                blobsImported: nil
            )
        }
        return try await transport.request(
            method: .post, path: "/items/bulk", body: input, query: nil
        )
    }

    /// Applies one action to every item matching the filter. Six actions
    /// — `transition`, `purge`, `update_tags`, `update_tier`,
    /// `update_properties`, `update_timestamp`.
    ///
    /// Pure-local mode resolves the filter locally via
    /// ``LocalStore/fetchItems(filters:)`` and fans out to the per-item
    /// local equivalents (``LocalStore/transitionItem(id:to:)``,
    /// ``LocalStore/purgeItem(id:)``, etc.). Synced mode enqueues the
    /// input as a single ``MutationKind/bulkAction`` record for replay.
    ///
    /// Remote mode (T-218): the server returns 200 for dry-run
    /// (synchronous) and 202 + a ``BulkActionJob`` envelope for every
    /// other action. The default shape of `bulkAction` keeps callers
    /// blissfully unaware — polls internally until the job reaches a
    /// terminal state and resolves with the embedded ``BulkActionResult``
    /// exactly as the older synchronous endpoint did. Pass
    /// ``BulkActionPollOptions`` to tune intervals or hook
    /// ``BulkActionPollOptions/onProgress`` for live UI updates.
    public func bulkAction(
        _ input: BulkActionInput,
        options: BulkActionPollOptions = .default
    ) async throws -> BulkActionResult {
        if let store = localStore {
            return try await applyBulkActionLocally(input, store: store)
        }
        return try await BulkActionRunner.runToCompletion(
            transport: transport,
            input: input,
            options: options
        )
    }

    /// T-218: POST `/items/bulk_action` and return the initial
    /// ``BulkActionJob`` envelope without polling. Suits callers that
    /// want explicit control over the lifecycle — UI surfaces that
    /// render progress directly, agents returning a job id to the
    /// caller, etc. Drive polling yourself via
    /// ``bulkActionStatus(jobId:)``.
    ///
    /// Throws on `dry_run: true` — that path stays synchronous on the
    /// server, so callers should use ``bulkAction(_:options:)`` for
    /// dry-runs.
    public func bulkActionAsync(_ input: BulkActionInput) async throws -> BulkActionJob {
        if localStore != nil {
            throw MymeError(
                code: "not_supported",
                message: "bulkActionAsync is remote-mode only; use bulkAction(_:) for pure-local / synced clients",
                status: 0
            )
        }
        switch try await BulkActionRunner.post(transport: transport, input: input) {
        case .inline:
            throw MymeError(
                code: "invalid_request",
                message: "bulkActionAsync does not support dry_run; use bulkAction(_:options:) for the synchronous dry-run path",
                status: 400
            )
        case .queued(let job):
            return job
        }
    }

    /// T-218: single GET against `/items/bulk_action/jobs/:id`. The
    /// caller is responsible for back-off — see
    /// ``BulkActionPollOptions`` if you want the SDK to drive the loop.
    public func bulkActionStatus(jobId: String) async throws -> BulkActionJob {
        try await transport.request(
            method: .get,
            path: "/items/bulk_action/jobs/\(jobId)",
            body: nil,
            query: nil
        )
    }

    /// T-218: request cancellation of a bulk_action job. Idempotent —
    /// already-terminal jobs return their existing final state
    /// unchanged. The worker observes the flag between chunks and
    /// stops; the response from this call surfaces the row as-of-now,
    /// which may still show `in_progress` if the worker hasn't yet
    /// observed it.
    public func bulkActionCancel(jobId: String) async throws -> BulkActionJob {
        try await transport.request(
            method: .delete,
            path: "/items/bulk_action/jobs/\(jobId)",
            body: nil,
            query: nil
        )
    }

    private func applyBulkActionLocally(
        _ input: BulkActionInput,
        store: LocalStore
    ) async throws -> BulkActionResult {
        let (filter, options, actionName) = destructureAction(input)

        // Resolve the match set with the same `ListFilters` that
        // `GET /items` would, so the local fan-out mirrors the server's
        // server-side narrowing.
        var list = ListFilters()
        list.type = filter.type
        list.state = filter.state
        list.source = filter.source
        list.tier = filter.tier
        list.tags = filter.tags
        list.since = filter.since
        list.until = filter.until
        list.filter = filter.filter
        list.limit = options.maxItems

        let matched = try await store.fetchItems(filters: list)

        if options.dryRun == true {
            return BulkActionResult(
                action: actionName,
                matched: matched.data.count,
                succeeded: 0,
                errored: 0,
                dryRun: true,
                ids: matched.data.map(\.id),
                errors: nil,
                blobHashesReferenced: nil
            )
        }

        var succeeded = 0
        var errors: [BulkActionErrorEntry] = []
        let succeededIds = try await applyLocalAction(
            input, matched: matched.data, store: store, errors: &errors,
            succeeded: &succeeded
        )

        try await mutationQueue?.enqueueBulkAction(input)

        return BulkActionResult(
            action: actionName,
            matched: matched.data.count,
            succeeded: succeeded,
            errored: errors.count,
            dryRun: false,
            ids: succeededIds.count <= 100 ? succeededIds : nil,
            errors: errors.isEmpty ? nil : errors,
            blobHashesReferenced: nil
        )
    }

    private func destructureAction(
        _ input: BulkActionInput
    ) -> (BulkActionFilter, BulkActionOptions, String) {
        switch input {
        case .transition(let filter, _, let options):
            return (filter, options, "transition")
        case .purge(let filter, let options):
            return (filter, options, "purge")
        case .updateTags(let filter, _, _, let options):
            return (filter, options, "update_tags")
        case .updateTier(let filter, _, let options):
            return (filter, options, "update_tier")
        case .updateProperties(let filter, _, let options):
            return (filter, options, "update_properties")
        case .updateTimestamp(let filter, _, let options):
            return (filter, options, "update_timestamp")
        }
    }

    private func applyLocalAction(
        _ input: BulkActionInput,
        matched: [Item],
        store: LocalStore,
        errors: inout [BulkActionErrorEntry],
        succeeded: inout Int
    ) async throws -> [String] {
        var succeededIds: [String] = []

        for item in matched {
            do {
                switch input {
                case .transition(_, let state, _):
                    if item.state != state {
                        _ = try await store.transitionItem(id: item.id, to: state)
                    }
                case .purge:
                    try await store.purgeItem(id: item.id)
                case .updateTags(_, let add, let remove, _):
                    if let add, !add.isEmpty {
                        _ = try await store.addTags(itemId: item.id, tags: add)
                    }
                    if let remove {
                        for tag in remove {
                            try await store.removeTag(itemId: item.id, tag: tag)
                        }
                    }
                case .updateTier(_, let tier, _):
                    _ = try await store.updateItem(
                        id: item.id, properties: item.properties, tier: tier
                    )
                case .updateProperties(_, let patch, _):
                    // Shallow merge locally to match server semantics.
                    var merged = item.properties
                    for (k, v) in patch { merged[k] = v }
                    _ = try await store.updateItem(
                        id: item.id, properties: merged, tier: nil
                    )
                case .updateTimestamp:
                    // LocalStore doesn't expose a timestamp-only setter
                    // today; treat locally as a no-op and let replay
                    // carry the change on the server. Reported as
                    // succeeded so the counts match synced-mode intent.
                    break
                }
                succeededIds.append(item.id)
                succeeded += 1
            } catch {
                errors.append(BulkActionErrorEntry(
                    id: item.id,
                    code: "local_error",
                    message: String(describing: error)
                ))
            }
        }
        return succeededIds
    }

    // MARK: - Pagination helpers

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
