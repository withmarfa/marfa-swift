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

    // MARK: - Mutations

    /// Creates a new edge between two items.
    public func create(
        source: String,
        target: String,
        edgeType: String,
        properties: [String: JSONValue]? = nil
    ) async throws -> Edge {
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

    /// Updates an edge's properties. `edge_type`, `source_id`, and `target_id`
    /// are immutable — the server rejects changes to those.
    public func update(
        id: String,
        properties: [String: JSONValue]
    ) async throws -> Edge {
        let body = UpdateEdgeBody(properties: properties)
        let response: EdgeResponse = try await transport.request(
            method: .patch, path: "/edges/\(id)", body: body, query: nil
        )
        return response.edge
    }

    /// Deletes an edge.
    public func delete(id: String) async throws {
        let _: EmptyResponse = try await transport.request(
            method: .delete, path: "/edges/\(id)", body: nil, query: nil
        )
    }

    // MARK: - Reads

    /// Lists outbound edges from a source item — edges where `source_id == sourceId`.
    /// Mirrors `client.items.edges(id:)`; exposed here for symmetry when the
    /// caller is thinking about the edge graph directly.
    public func listFromSource(
        sourceId: String,
        edgeType: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> PaginatedResult<Edge> {
        var query: [(String, String)] = []
        if let edgeType { query.append(("edge_type", edgeType)) }
        if let cursor { query.append(("cursor", cursor)) }
        if let limit { query.append(("limit", String(limit))) }
        return try await transport.request(
            method: .get, path: "/items/\(sourceId)/edges", body: nil,
            query: query.isEmpty ? nil : query
        )
    }

    /// Lists inbound edges pointing at a target item — edges where
    /// `target_id == targetId`. Mirrors `client.items.backrefs(id:)`.
    public func listToTarget(
        targetId: String,
        edgeType: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> PaginatedResult<Edge> {
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

    /// Async sequence walking every outbound edge from `sourceId`, paging
    /// through cursors automatically.
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

    /// Async sequence walking every inbound edge to `targetId`, paging
    /// through cursors automatically.
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

/// Response envelope for single-edge endpoints: `{ "edge": ... }`.
struct EdgeResponse: Codable, Sendable {
    let edge: Edge
}
