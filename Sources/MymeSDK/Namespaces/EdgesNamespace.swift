import Foundation

/// Edges API namespace. Manages typed relationships between items.
///
/// An edge is `(source, target, edge_type, properties)` where `source`/`target`
/// are item IDs and `edge_type` is one of the registered edge types
/// (`in-thread`, `parent-of`, `annotates`, `about`, `authored-by`,
/// `pinned-to`, `derived-from`, `supersedes`). Edge-type registration is
/// intentionally not exposed here — it's an admin-level concern.
public struct EdgesNamespace: Sendable {

    let transport: any Transport
    let localStore: LocalStore?
    let mutationQueue: MutationQueue?

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
            try? await mutationQueue?.enqueueCreateEdge(
                source: source, target: target,
                edgeType: edgeType, properties: properties,
                localEdgeId: edge.id
            )
            return edge
        }
        let body = CreateEdgeBody(
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
            try? await mutationQueue?.enqueueUpdateEdge(id: id, properties: properties)
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
            try? await mutationQueue?.enqueueDeleteEdge(id: id)
            return
        }
        let _: EmptyResponse = try await transport.request(
            method: .delete, path: "/edges/\(id)", body: nil, query: nil
        )
    }

    // MARK: - Reads

    /// Lists outbound edges from a source item.
    public func listFromSource(
        sourceId: String,
        edgeType: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> PaginatedResult<Edge> {
        if let store = localStore {
            return try await store.fetchEdgesFromSource(
                sourceId: sourceId, edgeType: edgeType, limit: limit
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
                targetId: targetId, edgeType: edgeType, limit: limit
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

// MARK: - Bodies / Envelopes

/// Request body for `POST /edges`.
struct CreateEdgeBody: Codable, Sendable {
    let sourceId: String
    let targetId: String
    let edgeType: String
    let properties: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
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
