import Foundation

// MARK: - /edges/bulk — list-in

/// One edge to create-or-upsert in a `POST /edges/bulk` call.
///
/// Idempotency key is `(source_id, target_id, edge_type)`. In `upsert` mode
/// a duplicate triple replaces properties in place; in `createOnly` mode
/// it surfaces as ``BulkOutcome/skipped`` with reason `"duplicate_edge"`.
public struct BulkEdgeInputItem: Codable, Sendable {
    /// The caller's own id for this edge. A synced client writes the local
    /// row under it and sends it on replay, so it names the row on both
    /// sides. Omitted, the id is minted — locally by the store on a synced
    /// client, by the server otherwise.
    public var id: String?
    public var sourceId: String
    public var targetId: String
    public var edgeType: String
    public var properties: [String: JSONValue]?

    public init(
        id: String? = nil,
        sourceId: String,
        targetId: String,
        edgeType: String,
        properties: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.sourceId = sourceId
        self.targetId = targetId
        self.edgeType = edgeType
        self.properties = properties
    }

    enum CodingKeys: String, CodingKey {
        case id, properties
        case sourceId = "source_id"
        case targetId = "target_id"
        case edgeType = "edge_type"
    }
}

/// Input envelope for `POST /edges/bulk`. Reuses ``BulkMode`` —
/// `upsert` (default on server) replaces properties on duplicates;
/// `createOnly` skips them.
public struct BulkEdgeInput: Codable, Sendable {
    public var edges: [BulkEdgeInputItem]
    public var mode: BulkMode?
    /// Defaults to `true` on the server — set `false` for best-effort ingest.
    public var atomic: Bool?
    /// Per-edge events default to OFF on bulk calls unless the caller opts
    /// in. When set, the call fires `edge.created` for each edge it created
    /// and `edge.updated` for each upsert that replaced an existing edge's
    /// properties, so a subscriber cannot tell a bulk edit from one made
    /// through `PATCH /edges/{id}`. Outcomes that wrote nothing emit nothing.
    public var emitEvents: Bool?

    public init(
        edges: [BulkEdgeInputItem],
        mode: BulkMode? = nil,
        atomic: Bool? = nil,
        emitEvents: Bool? = nil
    ) {
        self.edges = edges
        self.mode = mode
        self.atomic = atomic
        self.emitEvents = emitEvents
    }

    enum CodingKeys: String, CodingKey {
        case edges, mode, atomic
        case emitEvents = "emit_events"
    }
}

/// Per-edge outcome on a `POST /edges/bulk` call. Mirrors
/// ``BulkResultEntry`` but kept distinct to keep the edges-bulk surface
/// self-describing; reusing ``BulkResultEntry`` directly would drag the
/// item-shaped doc comments onto the edges result.
public struct BulkEdgeResultEntry: Codable, Sendable {
    public let index: Int
    public let outcome: BulkOutcome
    public let id: String?
    public let reason: String?
    public let error: BulkResultError?

    public init(
        index: Int,
        outcome: BulkOutcome,
        id: String? = nil,
        reason: String? = nil,
        error: BulkResultError? = nil
    ) {
        self.index = index
        self.outcome = outcome
        self.id = id
        self.reason = reason
        self.error = error
    }
}

/// Result envelope from `POST /edges/bulk`. No `blobsImported` field —
/// edges carry no blob references. ``BulkResultCounts`` is reused
/// verbatim; the counts shape is identical to items.bulk.
public struct BulkEdgeResult: Codable, Sendable {
    public let counts: BulkResultCounts
    public let results: [BulkEdgeResultEntry]

    public init(counts: BulkResultCounts, results: [BulkEdgeResultEntry]) {
        self.counts = counts
        self.results = results
    }
}
