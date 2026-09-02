import Foundation

/// Edges API namespace. Manages typed relationships between items.
///
/// An edge is `(source, target, edge_type, properties)` where `source`/`target`
/// are item IDs and `edge_type` is one of the registered edge types — eight
/// core types (`parent-of`, `in-thread`, `about`, `authored-by`,
/// `derived-from`, `supersedes`, `attached-to`, `references`) plus any custom
/// types the space has registered via ``edgeTypes``.
public struct EdgesNamespace: Sendable {

    let transport: any Transport
    let localStore: LocalStore?
    let mutationQueue: MutationQueue?
    /// Carries the max-fan-out cap used by ``listToTargets`` in remote mode.
    let maxBackrefBatchConcurrency: Int

    /// Custom edge-type registration. Admin-only on the server.
    public var edgeTypes: EdgeTypesAPI {
        EdgeTypesAPI(transport: transport)
    }

    // MARK: - Mutations

    /// Creates a new edge between two items.
    public func create(
        source: String,
        target: String,
        edgeType: String,
        properties: [String: JSONValue]? = nil
    ) async throws -> Edge {
        if let store = localStore {
            let edge = try await store.createEdge(
                source: source, target: target,
                edgeType: edgeType, properties: properties
            )
            try await mutationQueue?.enqueueCreateEdge(
                source: source, target: target,
                edgeType: edgeType, properties: properties,
                localEdgeId: edge.id
            )
            return edge
        }
        // Network-only: nothing was written locally, so there is no id to
        // keep and the server mints one.
        let body = CreateEdgeBody(
            id: nil,
            sourceId: source,
            targetId: target,
            edgeType: edgeType,
            properties: properties
        )
        let response: EdgeResponse = try await transport.request(
            method: .post, path: "/edges", body: body, query: nil
        )
        return response.edge
    }

    /// Updates an edge's properties.
    public func update(
        id: String,
        properties: [String: JSONValue]
    ) async throws -> Edge {
        if let store = localStore {
            let edge = try await store.updateEdge(id: id, properties: properties)
            try await mutationQueue?.enqueueUpdateEdge(id: id, properties: properties)
            return edge
        }
        let body = UpdateEdgeBody(properties: properties)
        let response: EdgeResponse = try await transport.request(
            method: .patch, path: "/edges/\(id)", body: body, query: nil
        )
        return response.edge
    }

    /// Deletes an edge.
    public func delete(id: String) async throws {
        if let store = localStore {
            try await store.deleteEdge(id: id)
            try await mutationQueue?.enqueueDeleteEdge(id: id)
            return
        }
        let _: EmptyResponse = try await transport.request(
            method: .delete, path: "/edges/\(id)", body: nil, query: nil
        )
    }

    // MARK: - Bulk

    /// Creates or upserts many edges in one call (admin-only). Up to 5000
    /// edges per call server-side; use ``bulkAll(_:batchSize:progressHandler:)``
    /// to iterate larger sets.
    ///
    /// Modes (reuses ``BulkMode``):
    /// - ``BulkMode/upsert`` (default) — duplicate
    ///   `(source_id, target_id, edge_type)` triples replace properties in
    ///   place.
    /// - ``BulkMode/createOnly`` — duplicate triples surface as
    ///   ``BulkOutcome/skipped`` with reason `"duplicate_edge"`.
    ///
    /// Dispatches per client mode:
    /// - **Pure-local** — iterates edges through ``LocalStore/createEdge``
    ///   and returns best-effort per-edge outcomes. Duplicate-edge
    ///   detection is left to the local store; anything the store rejects
    ///   surfaces as ``BulkOutcome/errored``. No upsert path locally —
    ///   local edges have no cross-client properties contract to replace.
    /// - **Synced** — iterates locally for immediate feedback AND enqueues
    ///   a single ``MutationKind/bulkEdges`` record so replay POSTs the
    ///   whole call when the client reconnects. Each queued edge carries the
    ///   id its local row was written under, so the server stores the same
    ///   rows rather than minting a second set beside them.
    /// - **Network-only** — round-trips the server response straight
    ///   through.
    ///
    /// This is the companion to ``ItemsNamespace/bulk(_:)`` for the
    /// edges half of mode-transition migrations, where cross-item edges
    /// can't reliably ride along as inline-edge payloads on the item
    /// writes (source and target may land in different batches).
    public func bulk(_ input: BulkEdgeInput) async throws -> BulkEdgeResult {
        if let store = localStore {
            var created = 0
            var errored = 0
            var results: [BulkEdgeResultEntry] = []
            results.reserveCapacity(input.edges.count)

            // What the replay will send: the same call, with every edge
            // named by the id its local row was written under. Replaying the
            // caller's input verbatim let the server mint a second id for
            // each edge, and the echo then landed beside the local row
            // instead of on it.
            var stamped: [BulkEdgeInputItem] = []
            stamped.reserveCapacity(input.edges.count)

            for (index, raw) in input.edges.enumerated() {
                do {
                    let edge = try await store.createEdge(
                        id: raw.id,
                        source: raw.sourceId,
                        target: raw.targetId,
                        edgeType: raw.edgeType,
                        properties: raw.properties
                    )
                    var item = raw
                    item.id = edge.id
                    stamped.append(item)
                    results.append(BulkEdgeResultEntry(
                        index: index, outcome: .created, id: edge.id
                    ))
                    created += 1
                } catch {
                    // No local row was written, so there is nothing here for a
                    // server-minted id to duplicate. The item travels as the
                    // caller wrote it and the server names it.
                    stamped.append(raw)
                    results.append(BulkEdgeResultEntry(
                        index: index, outcome: .errored,
                        error: BulkResultError(
                            code: "local_error",
                            message: String(describing: error)
                        )
                    ))
                    errored += 1
                }
            }

            var replayed = input
            replayed.edges = stamped
            try await mutationQueue?.enqueueBulkEdges(replayed)

            return BulkEdgeResult(
                counts: BulkResultCounts(
                    created: created, updated: 0, skipped: 0, errored: errored
                ),
                results: results
            )
        }
        return try await transport.request(
            method: .post, path: "/edges/bulk", body: input, query: nil
        )
    }

    // MARK: - Reads

    /// Global space-scoped edge listing, optionally filtered by type.
    /// Use this when you need "all edges of type X" (thread-root counting,
    /// taxonomy traversal) — replaces the walk-every-item N+1 pattern.
    /// Per-target filters live on ``listFromSource`` / ``listToTarget``.
    ///
    /// In synced mode the SDK satisfies the call from the local store
    /// directly (fast, no round-trip); in remote mode it hits
    /// `GET /edges?edge_type=...`.
    public func list(
        edgeType: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> PaginatedResult<Edge> {
        if let store = localStore {
            return try await store.fetchEdges(
                edgeType: edgeType, cursor: cursor, limit: limit
            )
        }
        var query: [(String, String)] = []
        if let edgeType { query.append(("edge_type", edgeType)) }
        if let cursor { query.append(("cursor", cursor)) }
        if let limit { query.append(("limit", String(limit))) }
        return try await transport.request(
            method: .get, path: "/edges", body: nil,
            query: query.isEmpty ? nil : query
        )
    }

    /// Lists outbound edges from a source item.
    public func listFromSource(
        sourceId: String,
        edgeType: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> PaginatedResult<Edge> {
        if let store = localStore {
            return try await store.fetchEdgesFromSource(
                sourceId: sourceId, edgeType: edgeType, cursor: cursor, limit: limit
            )
        }
        var query: [(String, String)] = []
        if let edgeType { query.append(("edge_type", edgeType)) }
        if let cursor { query.append(("cursor", cursor)) }
        if let limit { query.append(("limit", String(limit))) }
        return try await transport.request(
            method: .get, path: "/items/\(sourceId)/edges", body: nil,
            query: query.isEmpty ? nil : query
        )
    }

    /// Lists inbound edges pointing at a target item.
    public func listToTarget(
        targetId: String,
        edgeType: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> PaginatedResult<Edge> {
        if let store = localStore {
            return try await store.fetchEdgesToTarget(
                targetId: targetId, edgeType: edgeType, cursor: cursor, limit: limit
            )
        }
        var query: [(String, String)] = []
        if let edgeType { query.append(("edge_type", edgeType)) }
        if let cursor { query.append(("cursor", cursor)) }
        if let limit { query.append(("limit", String(limit))) }
        return try await transport.request(
            method: .get, path: "/items/\(targetId)/backrefs", body: nil,
            query: query.isEmpty ? nil : query
        )
    }

    /// Batched backrefs lookup. Returns a dictionary keyed by every
    /// distinct target ID in `targetIds` (unknown IDs map to `[]`),
    /// with `limit` applied per target.
    ///
    /// Dispatches per client mode:
    /// - **Synced / pure-local** — one local SQL query over
    ///   `idx_edges_target`. `limit` caps the list per target.
    /// - **Remote-only** — fans out to `GET /items/:id/backrefs` with a
    ///   bounded concurrency window
    ///   (``ClientConfiguration/maxBackrefBatchConcurrency``, default 8).
    ///   Each per-target call observes its own `limit`; cursor-based
    ///   pagination is not supported in the batched variant. Callers
    ///   needing more pages per target should use ``listToTarget`` on the
    ///   specific ID.
    ///
    /// Empty `targetIds` short-circuits to `[:]` with no network or DB
    /// access. Duplicate IDs in the input are collapsed to distinct.
    ///
    /// > Note: The local path binds all distinct `targetIds` into a single
    /// > `IN(...)` clause, so SQLite's host-parameter limit applies
    /// > (typically 32,766 per statement). Callers with very large batches
    /// > (~30k+ IDs after de-duplication) should chunk the input themselves
    /// > and merge the per-chunk dictionaries.
    public func listToTargets(
        targetIds: [String],
        edgeType: String? = nil,
        limit: Int? = nil
    ) async throws -> [String: [Edge]] {
        guard !targetIds.isEmpty else { return [:] }
        let distinct = Array(Set(targetIds))
        if let store = localStore {
            return try await store.fetchEdgesToTargets(
                targetIds: distinct, edgeType: edgeType, limit: limit
            )
        }
        let cap = max(1, maxBackrefBatchConcurrency)
        return try await withThrowingTaskGroup(of: (String, [Edge]).self) { group in
            var iterator = distinct.makeIterator()
            var launched = 0
            while launched < cap, let id = iterator.next() {
                group.addTask {
                    let page = try await self.listToTarget(
                        targetId: id, edgeType: edgeType, cursor: nil, limit: limit
                    )
                    return (id, page.data)
                }
                launched += 1
            }
            var out: [String: [Edge]] = Dictionary(
                uniqueKeysWithValues: distinct.map { ($0, []) }
            )
            while let (id, edges) = try await group.next() {
                out[id] = edges
                if let next = iterator.next() {
                    group.addTask {
                        let page = try await self.listToTarget(
                            targetId: next, edgeType: edgeType, cursor: nil, limit: limit
                        )
                        return (next, page.data)
                    }
                }
            }
            return out
        }
    }

    // MARK: - Paginated sequences

    /// Async sequence walking every outbound edge from `sourceId`.
    public func allFromSource(
        sourceId: String,
        edgeType: String? = nil,
        pageSize: Int? = nil
    ) -> PaginatedSequence<Edge> {
        PaginatedSequence { cursor in
            try await self.listFromSource(
                sourceId: sourceId,
                edgeType: edgeType,
                cursor: cursor,
                limit: pageSize
            )
        }
    }

    /// Async sequence walking every inbound edge to `targetId`.
    public func allToTarget(
        targetId: String,
        edgeType: String? = nil,
        pageSize: Int? = nil
    ) -> PaginatedSequence<Edge> {
        PaginatedSequence { cursor in
            try await self.listToTarget(
                targetId: targetId,
                edgeType: edgeType,
                cursor: cursor,
                limit: pageSize
            )
        }
    }
}

// MARK: - Edge-types sub-namespace

/// Custom edge-type registration and listing.
///
/// Mirrors the TypeScript SDK's `client.edges.types` surface. Registration
/// (`create`) and deletion (`delete`) are admin-only on the server; non-admin
/// keys receive a 403.
public struct EdgeTypesAPI: Sendable {

    let transport: any Transport

    /// Registers a new custom edge type.
    ///
    /// - Throws: ``ForbiddenError`` when the API key lacks admin permission,
    ///   ``ValidationError`` when the schema conflicts with an existing type
    ///   or fails validation.
    @discardableResult
    public func create(_ input: CreateEdgeTypeInput) async throws -> EdgeType {
        let response: EdgeTypeResponse = try await transport.request(
            method: .post, path: "/edge-types", body: input, query: nil
        )
        return response.edgeType
    }

    /// Lists all registered edge types — the eight core types plus any
    /// custom types registered by the space.
    public func list() async throws -> [EdgeType] {
        let response: EdgeTypesListResponse = try await transport.request(
            method: .get, path: "/edge-types", body: nil, query: nil
        )
        return response.edgeTypes
    }

    /// Deletes a custom edge type by id. Core edge types cannot be deleted —
    /// the server rejects with a ``ValidationError``. Only custom types
    /// registered via ``create(_:)`` can be removed.
    public func delete(id: String) async throws {
        let _: EmptyResponse = try await transport.request(
            method: .delete, path: "/edge-types/\(id)", body: nil, query: nil
        )
    }
}

// MARK: - Bodies / Envelopes

/// Request body for `POST /edges`.
///
/// `id` names the edge the caller has already written locally. The route
/// stores it under that id and echoes it back, so the row a synced device
/// holds is the row the server holds. A client with no local row to name
/// omits it and the server mints one instead.
struct CreateEdgeBody: Codable, Sendable {
    let id: String?
    let sourceId: String
    let targetId: String
    let edgeType: String
    let properties: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case id
        case sourceId = "source_id"
        case targetId = "target_id"
        case edgeType = "edge_type"
        case properties
    }
}

/// Request body for `PATCH /edges/:id`.
struct UpdateEdgeBody: Codable, Sendable {
    let properties: [String: JSONValue]
}
