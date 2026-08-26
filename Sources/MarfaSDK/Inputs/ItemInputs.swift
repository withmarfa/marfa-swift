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
    /// Outbound edges to create atomically with the item, as
    /// `{ <edge_type>: [targetId] }`.
    ///
    /// Outbound only, and carrying no per-edge properties, because that is
    /// what `POST /items` accepts. An edge that needs a direction of its own
    /// or properties on it is a separate `client.edges.create(...)` call
    /// against the item this returns.
    public var edges: [String: [String]]?

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
        edges: [String: [String]]? = nil
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

struct UpdateItemBody: Codable, Sendable {
    var properties: [String: JSONValue]?
    var version: Int?
    /// Force a version snapshot on this write.
    ///
    /// The key is `force_snapshot`. It was `snapshot` here, which the route
    /// does not read, so the flag encoded and did nothing. Nothing set it,
    /// so nothing broke; it was waiting for the first caller.
    var forceSnapshot: Bool?
    var tier: Tier?
    /// Rename the natural key under this item's `source`. Server validates
    /// uniqueness of `(source, source_id)` and 409s with
    /// `source_id_conflict` on collision. Independent of the version-merge
    /// path; never participates in `conflicting_fields`.
    var sourceId: String?

    enum CodingKeys: String, CodingKey {
        case properties, version, tier
        case forceSnapshot = "force_snapshot"
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

struct TransitionBody: Codable, Sendable {
    let state: ItemState
}
