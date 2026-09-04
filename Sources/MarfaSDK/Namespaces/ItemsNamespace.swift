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
    /// Where a synced-mode `.callback` update finds the app's resolver. The
    /// per-call closure cannot survive the mutation queue, so in synced mode
    /// the registry is the only thing a replay can reach.
    let conflictResolvers: ConflictResolverRegistry?

    init(
        transport: any Transport,
        defaultConflictStrategy: ConflictStrategy,
        localStore: LocalStore? = nil,
        mutationQueue: MutationQueue? = nil,
        apiBaseURL: URL? = nil,
        conflictResolvers: ConflictResolverRegistry? = nil
    ) {
        self.transport = transport
        self.defaultConflictStrategy = defaultConflictStrategy
        self.localStore = localStore
        self.mutationQueue = mutationQueue
        self.apiBaseURL = apiBaseURL
        self.conflictResolvers = conflictResolvers
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
            // One store call rather than a metadata fetch per item. The task
            // group this replaces also collected in completion order, so the
            // page came back in whatever order the reads happened to finish
            // — losing the sort the caller asked for — and it discarded the
            // cursor and `hasMore` it had just been handed.
            return try await store.fetchItemsWithMetadataPage(filters: filters)
        }
        var params = filters?.toQueryParams() ?? []
        params.append(("include", "metadata"))
        return try await transport.request(
            method: .get, path: "/items", body: nil, query: params
        )
    }

    /// Updates an item's properties with conflict resolution.
    ///
    /// **Send only the fields you changed, and the version you read.**
    /// Conflict detection counts every submitted key as a client change, so a
    /// patch that echoes untouched fields manufactures conflicts against edits
    /// nobody made — under `keep_both_copies` each one spawns a sibling item
    /// holding text the user never typed, which reads as corruption. Omitted
    /// fields keep their server values: properties merge shallowly, so a
    /// partial patch is safe by construction. Pass ``UpdateOptions/version``
    /// from the item the edit was based on; an update without one opts out of
    /// detection entirely and reports nothing when it overwrites.
    ///
    /// In local mode the update is applied directly (no conflict resolution
    /// needed). In synced mode the local store is updated immediately and the
    /// mutation enqueued for replay; the per-call conflict strategy is
    /// captured with the queued mutation so replay applies the strategy the
    /// caller chose.
    ///
    /// A `.callback` strategy in synced mode resolves through the resolver
    /// registered on the client rather than the per-call closure, because a
    /// closure cannot be written to the mutation queue. Calling it with no
    /// resolver registered throws ``ConflictResolverMissingError`` here, at
    /// the point of the mistake, instead of silently resolving as `.auto`
    /// during a replay nobody is watching.
    public func update(
        id: String,
        properties: [String: JSONValue],
        options: UpdateOptions? = nil
    ) async throws -> Item {
        if let store = localStore {
            let queuedStrategy = options?.conflict ?? defaultConflictStrategy
            if queuedStrategy == .callback,
                options?.resolve == nil,
                await conflictResolvers?.current() == nil
            {
                // Nothing to call, anywhere: no per-call closure and no
                // registered resolver. Refusing here is the alternative to
                // resolving under a strategy the caller did not choose.
                //
                // A per-call closure alone is accepted, on this branch only.
                // A write that lands in the local store first has nothing to
                // collide with, so nothing here calls the closure; the
                // collision, if there is one, happens at replay. What runs
                // there is the registered resolver rather than this closure,
                // because a closure cannot be written to the mutation queue.
                // Accepting the closure says the caller has thought about
                // resolution; registering one is what makes the replay honor
                // it. (The remote path below is the other story: no store, no
                // queue, and the closure is called on the 409 itself.)
                //
                // Which advice is true depends on which client this is, and
                // the two are told apart by the queue. A local-only client
                // has none, so it never replays and can reach no resolver at
                // all; telling its caller to register one sends them back to
                // a method that does nothing on that client.
                throw ConflictResolverMissingError(
                    message: mutationQueue == nil
                        ? "A local-only client cannot honor the .callback conflict strategy. It never syncs, so no conflict can arise and no resolver would ever run; registerConflictResolver(_:) has no effect on this client. Use .auto or .manual, or pass `resolve:` if the same code also runs against a synced client."
                        : "A synced-mode update asked for the .callback conflict strategy with no resolver to call: none was passed to this call and none is registered on the client. Pass `resolve:`, or register one with client.registerConflictResolver(_:)."
                )
            }
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

    /// Promotes an item from the feed tier into the library.
    ///
    /// The tier axis is orthogonal to lifecycle state: promoting says the
    /// item is worth keeping, and says nothing about whether it is active or
    /// archived. Promoting an item already in the library is a no-op that
    /// still returns it, so a caller need not check first.
    ///
    /// - Parameter id: The item id.
    /// - Returns: The item at its new tier.
    public func promote(id: String) async throws -> Item {
        guard localStore == nil || mutationQueue != nil else {
            throw LocalModeUnsupportedError(operation: "items.promote")
        }
        let response: ItemResponse = try await transport.request(
            method: .post, path: "/items/\(id)/promote", body: nil, query: nil
        )
        return response.item
    }

    /// Compares an item against the upstream records that mirror it.
    ///
    /// An item synced from a connected service has a counterpart upstream,
    /// and the two drift: a field edited in Marfa, a field edited in the
    /// other application, a field only one side has ever had. This reports
    /// that comparison per field rather than resolving it — nothing is
    /// written, and deciding what to do with a divergence is the caller's.
    ///
    /// - Parameter id: The item id.
    /// - Returns: One entry per mirroring record, each with its field-level
    ///   comparison. Empty when the item mirrors nothing.
    public func reconcile(id: String) async throws -> [ReconcileMirror] {
        guard localStore == nil || mutationQueue != nil else {
            throw LocalModeUnsupportedError(operation: "items.reconcile")
        }
        let response: ReconcileResponse = try await transport.request(
            method: .get, path: "/items/\(id)/reconcile", body: nil, query: nil
        )
        return response.mirrors
    }

    /// Expands recurring events into dated occurrences across a window.
    ///
    /// A recurring event is stored once, as a rule; the dates it lands on are
    /// derived rather than stored, so a calendar cannot be built by listing
    /// items. This returns one entry per date in the window, with exceptions
    /// applied — an occurrence the user moved or cancelled reflects that
    /// rather than the rule.
    ///
    /// The window is required in both directions, because an unbounded
    /// expansion of an open-ended rule does not terminate.
    ///
    /// - Parameters:
    ///   - from: Start of the window, as an instant.
    ///   - to: End of the window, as an instant.
    ///   - type: Narrow to one event type. All event types when omitted.
    /// - Returns: Occurrences in the window, ascending by start.
    public func occurrences(
        from: String,
        to: String,
        type: String? = nil
    ) async throws -> [Occurrence] {
        guard localStore == nil || mutationQueue != nil else {
            throw LocalModeUnsupportedError(operation: "items.occurrences")
        }
        var query: [(String, String)] = [("from", from), ("to", to)]
        if let type { query.append(("type", type)) }
        let response: OccurrencesResponse = try await transport.request(
            method: .get, path: "/occurrences", body: nil, query: query
        )
        return response.data
    }

    /// Permanently removes a trashed item. Irreversible.
    ///
    /// The item must already be in the `trashed` state — call ``delete(id:)``
    /// first if needed. The route is space-admin gated, so a key without that
    /// role is refused. There is no purge *scope* to grant — naming one here
    /// sends a caller looking for something to add that does not exist.
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
                sourceId: id, edgeType: edgeType, cursor: cursor, limit: limit
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
                targetId: id, edgeType: edgeType, cursor: cursor, limit: limit
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
    /// Dispatches per client mode:
    /// - **Pure-local** — iterates the items through
    ///   ``LocalStore/createItem(_:)`` and returns best-effort per-item
    ///   outcomes. No dedup on `(source, source_id)` at the local layer,
    ///   because local stores do not carry that uniqueness constraint.
    /// - **Synced** — iterates locally for immediate feedback AND enqueues
    ///   a single ``MutationKind/bulk`` record so replay POSTs the whole
    ///   call when the client reconnects. Each queued entry carries the id
    ///   its local row was written under, so the server stores the same rows
    ///   rather than minting a second set beside them.
    /// - **Network-only** — round-trips the server response straight
    ///   through.
    public func bulk(_ input: BulkInput) async throws -> BulkResult {
        if let store = localStore {
            var created = 0
            var errored = 0
            var results: [BulkResultEntry] = []
            results.reserveCapacity(input.items.count)

            // What the replay will send: the same page, with every entry named
            // by the id its local row was written under. Replaying the caller's
            // input verbatim let the server mint a second id for each entry the
            // caller had not named, and the row that came back then landed
            // beside the local one instead of on it.
            //
            // Seeded from the caller's own page and mutated in place, so it
            // stays index-aligned with both `input.items` and the `results`
            // the caller is handed, by construction. Building it by appending
            // would put that alignment in the hands of every exit path in the
            // loop below, the one where a local write fails included — and an
            // entry missing there does not lose one row, it shifts every later
            // entry onto the wrong result.
            var stampedItems = input.items

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
                    // The store's id names the local row, so it is the one the
                    // replay has to send. An entry whose write failed keeps the
                    // caller's own value untouched: there is no local row for a
                    // server-minted id to duplicate.
                    stampedItems[index].id = item.id
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

            var replayed = input
            replayed.items = stampedItems
            try await mutationQueue?.enqueueBulk(replayed)

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
    /// In remote mode, the server returns 200 for dry-run (synchronous) and
    /// 202 + a ``BulkActionJob`` envelope for every other action. The default
    /// shape of `bulkAction` keeps callers blissfully unaware — polls
    /// internally until the job reaches a terminal state and resolves with
    /// the embedded ``BulkActionResult``. Pass ``BulkActionPollOptions`` to
    /// tune intervals or hook ``BulkActionPollOptions/onProgress`` for live
    /// UI updates.
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

    /// POST `/items/bulk-actions` and return the initial ``BulkActionJob``
    /// envelope without polling. Suits callers that want explicit control
    /// over the lifecycle — UI surfaces that render progress directly,
    /// agents returning a job id to the caller, etc. Drive polling yourself
    /// via ``bulkActionStatus(jobId:)``.
    ///
    /// Throws on `dry_run: true` — that path stays synchronous on the
    /// server, so callers should use ``bulkAction(_:options:)`` for
    /// dry-runs.
    public func bulkActionAsync(_ input: BulkActionInput) async throws -> BulkActionJob {
        if localStore != nil {
            throw MarfaError(
                code: "not_supported",
                message: "bulkActionAsync is remote-mode only; use bulkAction(_:) for pure-local / synced clients",
                status: 0
            )
        }
        switch try await BulkActionRunner.post(transport: transport, input: input) {
        case .inline:
            throw MarfaError(
                code: "invalid_request",
                message: "bulkActionAsync does not support dry_run; use bulkAction(_:options:) for the synchronous dry-run path",
                status: 400
            )
        case .queued(let job):
            return job
        }
    }

    /// Single GET against `/items/bulk-actions/jobs/:id`. The caller is
    /// responsible for back-off — see ``BulkActionPollOptions`` if you
    /// want the SDK to drive the loop.
    public func bulkActionStatus(jobId: String) async throws -> BulkActionJob {
        try await transport.request(
            method: .get,
            path: "/items/bulk-actions/jobs/\(jobId)",
            body: nil,
            query: nil
        )
    }

    /// Request cancellation of a bulk_action job. Idempotent — already-terminal
    /// jobs return their existing final state unchanged. The worker observes
    /// the flag between chunks and stops; the response surfaces the row
    /// as-of-now, which may still show `in_progress` if the worker hasn't
    /// yet observed the cancel.
    public func bulkActionCancel(jobId: String) async throws -> BulkActionJob {
        try await transport.request(
            method: .delete,
            path: "/items/bulk-actions/jobs/\(jobId)",
            body: nil,
            query: nil
        )
    }

    private func applyBulkActionLocally(
        _ input: BulkActionInput,
        store: LocalStore
    ) async throws -> BulkActionResult {
        let (filter, options, actionName) = destructureAction(input)

        // Everything that can refuse this action refuses it here, before a row
        // is read or touched. That ordering is the substance rather than
        // tidiness: each of these used to be enforced somewhere downstream of
        // the fan-out, or not at all, so the action was applied and *then* the
        // caller was told it should not have been.

        // `filter` is the server's expression grammar. It reaches across edges
        // and is evaluated server-side; the local store does not implement it
        // and says so in its own docblock. Passing it down anyway resolved to
        // every row the remaining fields allowed and applied the action to all
        // of them — and `purge` is one of the actions, so an expression naming
        // nothing emptied the store.
        //
        // Refusing beats approximating: a local evaluator would be a second
        // implementation of a grammar the server owns, and the two would drift.
        if filter.filter != nil {
            throw LocalFilterUnsupportedError(
                operation: "items.bulkAction", field: "filter"
            )
        }

        // The purge confirmation was enforced only by `BulkActionInput`'s
        // encoder, which runs at `enqueueBulkAction` — *after* the fan-out. So
        // a synced client purged every matching row locally, threw on the way
        // to the queue, and queued nothing: the caller saw an error and could
        // reasonably conclude nothing had happened, while the rows were gone
        // and only a full re-import would bring them back. A pure-local client
        // has no queue, so the encoder never ran and the confirmation was not
        // enforced at all.
        if case .purge = input, options.confirm != "PURGE" {
            throw BulkConfirmationRequiredError()
        }

        // Resolve the match set with the same `ListFilters` that `GET /items`
        // would, so the local fan-out narrows the way the server's does.
        var list = ListFilters()
        list.type = filter.type
        list.state = filter.state
        list.source = filter.source
        list.tier = filter.tier
        list.tags = filter.tags
        list.since = filter.since
        list.until = filter.until

        // `maxItems` is deliberately *not* `list.limit`. The server's
        // `max_items` caps the match set before a `bulk_cap_exceeded` error —
        // it refuses the action rather than trimming it. Passing it down as a
        // fetch window inverted that: a purge capped at one row purged one
        // arbitrary row of the many that matched, reported `matched: 1` so
        // nothing downstream could tell, and returned success. A caller
        // reaching for a cap is reaching for a brake, and a brake that
        // silently becomes a partial write is worse than no brake.
        //
        // The count is therefore taken over the unwindowed set and compared.
        let matched = try await store.fetchItems(filters: list)
        if let cap = options.maxItems, matched.data.count > cap {
            throw BulkCapExceededError(matched: matched.data.count, cap: cap)
        }

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
