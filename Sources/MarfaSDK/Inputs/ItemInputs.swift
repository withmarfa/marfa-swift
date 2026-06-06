import Foundation

/// Input for creating a new item.
///
/// Item-to-item relationships (parent-of, in-thread, about, etc.) are no
/// longer fields on the item body — create the relationship by adding an
/// entry to `edges` (an atomic item-plus-edges write), or post the edge
/// separately through `client.edges.create(...)`.
public struct CreateItemInput: Codable, Sendable {
    public var type: String
    public var properties: [String: JSONValue]
    public var id: String?
    public var state: ItemState?
    public var timestamp: String?
    public var source: String?
    public var sourceId: String?
    public var device: String?
    public var tier: Tier?
    public var captureLatitude: Double?
    public var captureLongitude: Double?
    public var tags: [String]?
    public var edges: [CreateItemEdge]?

    public init(
        type: String,
        properties: [String: JSONValue],
        id: String? = nil,
        state: ItemState? = nil,
        timestamp: String? = nil,
        source: String? = nil,
        sourceId: String? = nil,
        device: String? = nil,
        tier: Tier? = nil,
        captureLatitude: Double? = nil,
        captureLongitude: Double? = nil,
        tags: [String]? = nil,
        edges: [CreateItemEdge]? = nil
    ) {
        self.type = type
        self.properties = properties
        self.id = id
        self.state = state
        self.timestamp = timestamp
        self.source = source
        self.sourceId = sourceId
        self.device = device
        self.tier = tier
        self.captureLatitude = captureLatitude
        self.captureLongitude = captureLongitude
        self.tags = tags
        self.edges = edges
    }

    enum CodingKeys: String, CodingKey {
        case type, properties, id, state, timestamp, source, device, tier, tags, edges
        case sourceId = "source_id"
        case captureLatitude = "capture_latitude"
        case captureLongitude = "capture_longitude"
    }
}

/// One edge to attach atomically when creating an item.
///
/// `direction` picks whether the new item is the edge's source or target.
/// `otherId` is the already-existing item on the other side.
public struct CreateItemEdge: Codable, Sendable, Hashable {
    public enum Direction: String, Codable, Sendable, Hashable {
        /// The new item is the edge's source; `otherId` is the target.
        case outbound
        /// The new item is the edge's target; `otherId` is the source.
        case inbound
    }

    public var edgeType: String
    public var direction: Direction
    public var otherId: String
    public var properties: [String: JSONValue]?

    public init(
        edgeType: String,
        direction: Direction,
        otherId: String,
        properties: [String: JSONValue]? = nil
    ) {
        self.edgeType = edgeType
        self.direction = direction
        self.otherId = otherId
        self.properties = properties
    }

    enum CodingKeys: String, CodingKey {
        case edgeType = "edge_type"
        case direction
        case otherId = "other_id"
        case properties
    }
}

/// Body for PATCH /items/:id.
struct UpdateItemBody: Codable, Sendable {
    var properties: [String: JSONValue]?
    var version: Int?
    var snapshot: Bool?
    var tier: Tier?
    /// Rename the natural key under this item's `source`. Server validates
    /// uniqueness of `(source, source_id)` and 409s with
    /// `source_id_conflict` on collision. Independent of the version-merge
    /// path; never participates in `conflicting_fields`.
    var sourceId: String?

    enum CodingKeys: String, CodingKey {
        case properties, version, snapshot, tier
        case sourceId = "source_id"
    }
}

/// Options for item update operations.
public struct UpdateOptions: Sendable {
    public var version: Int?
    public var conflict: ConflictStrategy?
    public var resolve: ConflictResolver?
    /// Move the item to the given tier as part of this update. Independent
    /// of the version-merge path; never conflicts.
    public var tier: Tier?
    /// Rename the item's `source_id` (natural key under its `source`).
    /// Server enforces `(source, source_id)` uniqueness; collisions return
    /// `409 source_id_conflict` rather than the version-conflict path.
    public var sourceId: String?

    public init(
        version: Int? = nil,
        conflict: ConflictStrategy? = nil,
        resolve: ConflictResolver? = nil,
        tier: Tier? = nil,
        sourceId: String? = nil
    ) {
        self.version = version
        self.conflict = conflict
        self.resolve = resolve
        self.tier = tier
        self.sourceId = sourceId
    }
}

/// Body for POST /items/:id/transition.
struct TransitionBody: Codable, Sendable {
    let state: ItemState
}
