import Foundation

// MARK: - SSE event payload envelopes

private struct ItemEventPayload: Decodable {
    let item: Item
}

private struct EdgeEventPayload: Decodable {
    let edge: Edge
}

private struct MetadataEventPayload: Decodable {
    let itemId: String
    let metadata: Metadata

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case metadata
    }
}

// MARK: - SyncEngine

/// Drives bidirectional synchronisation between the local SQLite store and the
/// Myme server.
///
/// ## Lifecycle
///
///     let engine = SyncEngine(
///         transport: transport,
///         localStore: store,
///         mutationQueue: queue,
///         connectionManager: connManager
///     )
///     await engine.start()  // begin; returns immediately
///     // ...
///     await engine.stop()   // tear down gracefully
///
/// ## What the engine does
///
/// 1. **Watches ``ConnectionStateManager``** — when the path goes from offline
///    to connecting, the engine opens a `GET /events` SSE stream with the last
///    persisted `Last-Event-ID` cursor so it receives only events since the
///    previous session.
///
/// 2. **Applies SSE events** — each server-sent event is decoded and written
///    into the local store via ``LocalStore`` upsert helpers. Supported event
///    types: `item.created`, `item.updated`, `item.deleted`, `item.restored`,
///    `item.state_changed`, `edge.created`, `edge.deleted`,
///    `metadata.changed`.
///
/// 3. **Persists the Last-Event-ID cursor** — after every applied event the
///    cursor is saved in the `sync_state` table so reconnection resumes from
///    the correct position.
///
/// 4. **Replays the mutation queue** — once the catch-up SSE stream reaches
///    idle (no events received for a short interval, or the stream signals
///    normal completion), the engine drains ``MutationQueue`` by sending each
///    pending mutation to the server. On success the record is removed; on
///    failure the attempt count is incremented and the engine retries on the
///    next reconnection cycle.
///
/// 5. **Coordinates state** — the engine calls ``ConnectionStateManager``
///    `.markSyncing()` while replaying mutations and `.markOnline()` when the
///    queue is empty and the SSE stream is idle.
public actor SyncEngine {

    // MARK: - Dependencies

    private let transport: any Transport
    private let localStore: LocalStore
    private let mutationQueue: MutationQueue
    private let connectionManager: ConnectionStateManager

    // MARK: - Internals

    private var streamTask: Task<Void, Never>?
    private var running = false

    // Sync-state key stored in the mutation-queue's sync_state table.
    private let cursorKey = "last_event_id"

    // MARK: - Init

    public init(
        transport: any Transport,
        localStore: LocalStore,
        mutationQueue: MutationQueue,
        connectionManager: ConnectionStateManager
    ) {
        self.transport = transport
        self.localStore = localStore
        self.mutationQueue = mutationQueue
        self.connectionManager = connectionManager
    }

    // MARK: - Lifecycle

    /// Starts the sync engine. Idempotent — calling again while already running
    /// is a no-op. Also starts the underlying ``ConnectionStateManager`` (which
    /// is itself idempotent) so `NWPathMonitor` begins delivering reachability
    /// updates; without this the engine's run loop would await on an inert
    /// stream stuck at `.offline`.
    public func start() async {
        guard !running else { return }
        running = true
        await connectionManager.start()
        streamTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Stops the sync engine and cancels the active SSE connection. Also stops
    /// the underlying ``ConnectionStateManager`` so `NWPathMonitor` releases
    /// its queue and any open `stateUpdates` streams finish.
    public func stop() async {
        running = false
        streamTask?.cancel()
        streamTask = nil
        await connectionManager.stop()
    }

    /// Performs a one-shot catch-up import: paginates through `GET
    /// /items?include=metadata` and upserts each item plus its metadata into
    /// the local store. SSE alone only delivers events since the cursor, so
    /// without this call a freshly-signed-in app shows an empty store even
    /// when the server has history.
    ///
    /// Safe to call repeatedly — `upsertItem` / `setMetadata` are idempotent.
    /// Edges are not imported here; they arrive via SSE once emitted. V1
    /// apps that need thread/about edges for initial state should call
    /// ``ItemsNamespace/list(filters:)`` or add a per-item edge fetch.
    ///
    /// - Parameter pageSize: Server-side page size for each request.
    /// - Returns: The total number of items imported across all pages.
    /// - Throws: Transport errors from the pagination requests, or upsert
    ///   errors from the local store.
    @discardableResult
    public func performInitialSync(pageSize: Int = 200) async throws -> Int {
        var cursor: String? = nil
        var imported = 0
        repeat {
            var query: [(String, String)] = [
                ("limit", String(pageSize)),
                ("include", "metadata"),
            ]
            if let cursor { query.append(("cursor", cursor)) }

            let page: PaginatedResult<ItemWithMetadata> = try await transport.request(
                method: .get, path: "/items", body: nil, query: query
            )

            for pair in page.data {
                try await localStore.upsertItem(pair.item)
                let input = MetadataInput(tags: pair.metadata.tags)
                _ = try await localStore.setMetadata(itemId: pair.item.id, input: input)
                imported += 1
            }

            if !page.hasMore {
                break
            }
            cursor = page.cursor
        } while cursor != nil
        return imported
    }

    // MARK: - Main run loop

    private func runLoop() async {
        for await state in await connectionManager.stateUpdates {
            guard running else { break }

            switch state {
            case .connecting:
                await openStream()
            case .offline:
                // Stream will be cancelled by Task cancellation if needed; do nothing.
                break
            case .online, .syncing:
                break
            }
        }
    }

    // MARK: - SSE stream

    private func openStream() async {
        let cursor = try? await mutationQueue.loadSyncState(key: cursorKey)

        var query: [(String, String)] = []
        if let cursor { query.append(("updated_after", cursor)) }

        let stream = transport.eventStream(
            path: "/events",
            query: query.isEmpty ? nil : query,
            lastEventID: cursor
        )

        do {
            for try await event in stream {
                guard running else { break }
                await applyEvent(event)
            }
        } catch {
            // Network/server error — record and let ConnectionStateManager
            // handle reconnect when the path recovers.
        }

        // Stream ended or errored — drain the mutation queue and go online.
        await replayMutations()
        if running {
            await connectionManager.markOnline()
        }
    }

    // MARK: - Event application

    private func applyEvent(_ event: SSEEvent) async {
        // Persist Last-Event-ID cursor before applying so we don't reprocess
        // on reconnect even if applying fails (events are idempotent upserts).
        if let id = event.id {
            try? await mutationQueue.saveSyncState(key: cursorKey, value: id)
        }

        guard let eventType = event.event else { return }
        let data = event.data.data(using: .utf8) ?? Data()
        let decoder = JSONDecoder()

        switch eventType {
        case "item.created", "item.updated", "item.restored", "item.state_changed":
            if let payload = try? decoder.decode(ItemEventPayload.self, from: data) {
                try? await localStore.upsertItem(payload.item)
            }

        case "item.deleted":
            // Server sends the deleted item with state = trashed/purged.
            if let payload = try? decoder.decode(ItemEventPayload.self, from: data) {
                try? await localStore.upsertItem(payload.item)
            }

        case "edge.created":
            if let payload = try? decoder.decode(EdgeEventPayload.self, from: data) {
                try? await localStore.upsertEdge(payload.edge)
            }

        case "edge.deleted":
            // Edge deletes carry just the edge ID in the data envelope.
            if let payload = try? decoder.decode(EdgeEventPayload.self, from: data) {
                try? await localStore.deleteEdge(id: payload.edge.id)
            }

        case "metadata.changed":
            if let payload = try? decoder.decode(MetadataEventPayload.self, from: data) {
                let input = MetadataInput(tags: payload.metadata.tags)
                _ = try? await localStore.setMetadata(itemId: payload.itemId, input: input)
            }

        default:
            break
        }
    }

    // MARK: - Mutation replay

    private func replayMutations() async {
        guard let pending = try? await mutationQueue.fetchAll(), !pending.isEmpty else { return }

        await connectionManager.markSyncing()
        let decoder = JSONDecoder()

        for record in pending {
            guard running else { break }

            do {
                try await replayRecord(record, decoder: decoder)
                try? await mutationQueue.remove(id: record.id)
            } catch {
                try? await mutationQueue.recordFailure(id: record.id, error: error.localizedDescription)
            }
        }
    }

    private func replayRecord(_ record: PendingMutationRecord, decoder: JSONDecoder) async throws {
        let data = record.payloadJson.data(using: .utf8) ?? Data()

        switch record.kind {

        case .createItem:
            let p = try decoder.decode(CreateItemPayload.self, from: data)
            let response: ItemResponse = try await transport.request(
                method: .post, path: "/items", body: p.input, query: nil
            )
            // Reconcile local-id → server-id in the local store.
            if let localId = record.localId, localId != response.item.id {
                try? await localStore.upsertItem(response.item)
                try? await localStore.purgeItem(id: localId)
            }

        case .updateItem:
            let p = try decoder.decode(UpdateItemPayload.self, from: data)
            let body = UpdateItemBody(properties: p.properties, version: nil, snapshot: nil)
            let _: ItemResponse = try await transport.request(
                method: .patch, path: "/items/\(p.id)", body: body, query: nil
            )

        case .deleteItem:
            let p = try decoder.decode(IDPayload.self, from: data)
            let _: EmptyResponse = try await transport.request(
                method: .delete, path: "/items/\(p.id)", body: nil, query: nil
            )

        case .restoreItem:
            let p = try decoder.decode(IDPayload.self, from: data)
            let _: ItemResponse = try await transport.request(
                method: .post, path: "/items/\(p.id)/restore", body: nil, query: nil
            )

        case .transitionItem:
            let p = try decoder.decode(TransitionPayload.self, from: data)
            let body = TransitionBody(state: p.state)
            let _: ItemResponse = try await transport.request(
                method: .post, path: "/items/\(p.id)/transition", body: body, query: nil
            )

        case .purgeItem:
            let p = try decoder.decode(IDPayload.self, from: data)
            let _: EmptyResponse = try await transport.request(
                method: .delete, path: "/items/\(p.id)/purge", body: nil, query: nil
            )

        case .createEdge:
            let p = try decoder.decode(CreateEdgePayload.self, from: data)
            let body = CreateEdgeBody(
                sourceId: p.source, targetId: p.target,
                edgeType: p.edgeType, properties: p.properties
            )
            let _: EdgeResponse = try await transport.request(
                method: .post, path: "/edges", body: body, query: nil
            )

        case .updateEdge:
            let p = try decoder.decode(UpdateEdgePayload.self, from: data)
            let _: EdgeResponse = try await transport.request(
                method: .patch, path: "/edges/\(p.id)",
                body: UpdateEdgeBody(properties: p.properties), query: nil
            )

        case .deleteEdge:
            let p = try decoder.decode(IDPayload.self, from: data)
            let _: EmptyResponse = try await transport.request(
                method: .delete, path: "/edges/\(p.id)", body: nil, query: nil
            )

        case .setMetadata:
            let p = try decoder.decode(MetadataPayload.self, from: data)
            let _: MetadataResponse = try await transport.request(
                method: .put, path: "/items/\(p.itemId)/metadata", body: p.input, query: nil
            )

        case .mergeMetadata:
            let p = try decoder.decode(MetadataPayload.self, from: data)
            let _: MetadataResponse = try await transport.request(
                method: .patch, path: "/items/\(p.itemId)/metadata", body: p.input, query: nil
            )

        case .addTags:
            let p = try decoder.decode(AddTagsPayload.self, from: data)
            let body = AddTagsBody(tags: p.tags)
            let _: MetadataResponse = try await transport.request(
                method: .post, path: "/items/\(p.itemId)/tags", body: body, query: nil
            )

        case .removeTag:
            let p = try decoder.decode(RemoveTagPayload.self, from: data)
            let _: MetadataResponse = try await transport.request(
                method: .delete, path: "/items/\(p.itemId)/tags/\(p.tag)", body: nil, query: nil
            )

        case .setExtension:
            let p = try decoder.decode(SetExtensionPayload.self, from: data)
            let encoded = p.namespace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p.namespace
            let _: ExtensionsResponse = try await transport.request(
                method: .put, path: "/items/\(p.itemId)/extensions/\(encoded)",
                body: p.data, query: nil
            )

        case .deleteExtension:
            let p = try decoder.decode(DeleteExtensionPayload.self, from: data)
            let encoded = p.namespace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p.namespace
            let _: EmptyResponse = try await transport.request(
                method: .delete, path: "/items/\(p.itemId)/extensions/\(encoded)",
                body: nil, query: nil
            )
        }
    }
}
