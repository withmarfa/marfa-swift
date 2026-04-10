import Foundation

/// A Myme item as returned by the API.
public struct Item: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let type: String
    public let state: ItemState
    public let properties: [String: JSONValue]
    public let createdAt: String
    public let updatedAt: String
    public let timestamp: String
    public let source: String?
    public let sourceId: String?
    public let origin: String?
    public let version: Int
    public let schemaVersion: Int?
    public let deviceId: String?
    public let parentId: String?
    public let threadId: String?
    public let captureLatitude: Double?
    public let captureLongitude: Double?

    public init(
        id: String, type: String, state: ItemState, properties: [String: JSONValue],
        createdAt: String, updatedAt: String, timestamp: String,
        source: String? = nil, sourceId: String? = nil, origin: String? = nil,
        version: Int, schemaVersion: Int? = nil, deviceId: String? = nil,
        parentId: String? = nil, threadId: String? = nil,
        captureLatitude: Double? = nil, captureLongitude: Double? = nil
    ) {
        self.id = id; self.type = type; self.state = state; self.properties = properties
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.timestamp = timestamp
        self.source = source; self.sourceId = sourceId; self.origin = origin
        self.version = version; self.schemaVersion = schemaVersion; self.deviceId = deviceId
        self.parentId = parentId; self.threadId = threadId
        self.captureLatitude = captureLatitude; self.captureLongitude = captureLongitude
    }

    enum CodingKeys: String, CodingKey {
        case id, type, state, properties, version, source, origin, timestamp
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case sourceId = "source_id"
        case schemaVersion = "schema_version"
        case deviceId = "device_id"
        case parentId = "parent_id"
        case threadId = "thread_id"
        case captureLatitude = "capture_latitude"
        case captureLongitude = "capture_longitude"
    }
}

/// Input for creating a new item.
public struct CreateItemInput: Codable, Sendable {
    public var type: String
    public var properties: [String: JSONValue]
    public var id: String?
    public var state: ItemState?
    public var timestamp: String?
    public var source: String?
    public var sourceId: String?
    public var origin: String?
    public var deviceId: String?
    public var parentId: String?
    public var threadId: String?
    public var captureLatitude: Double?
    public var captureLongitude: Double?
    public var tags: [String]?
    public var about: [String]?

    public init(
        type: String,
        properties: [String: JSONValue],
        id: String? = nil,
        state: ItemState? = nil,
        timestamp: String? = nil,
        source: String? = nil,
        sourceId: String? = nil,
        origin: String? = nil,
        deviceId: String? = nil,
        parentId: String? = nil,
        threadId: String? = nil,
        captureLatitude: Double? = nil,
        captureLongitude: Double? = nil,
        tags: [String]? = nil,
        about: [String]? = nil
    ) {
        self.type = type
        self.properties = properties
        self.id = id
        self.state = state
        self.timestamp = timestamp
        self.source = source
        self.sourceId = sourceId
        self.origin = origin
        self.deviceId = deviceId
        self.parentId = parentId
        self.threadId = threadId
        self.captureLatitude = captureLatitude
        self.captureLongitude = captureLongitude
        self.tags = tags
        self.about = about
    }

    enum CodingKeys: String, CodingKey {
        case type, properties, id, state, timestamp, source, origin, tags, about
        case sourceId = "source_id"
        case deviceId = "device_id"
        case parentId = "parent_id"
        case threadId = "thread_id"
        case captureLatitude = "capture_latitude"
        case captureLongitude = "capture_longitude"
    }
}

/// Body for PATCH /items/:id.
struct UpdateItemBody: Codable, Sendable {
    var properties: [String: JSONValue]
    var version: Int?
    var parentId: String?
    var threadId: String?
    var snapshot: Bool?

    enum CodingKeys: String, CodingKey {
        case properties, version, snapshot
        case parentId = "parent_id"
        case threadId = "thread_id"
    }
}

/// Options for item update operations.
public struct UpdateOptions: Sendable {
    public var version: Int?
    public var threadId: String?
    public var conflict: ConflictStrategy?
    public var resolve: ConflictResolver?

    public init(
        version: Int? = nil,
        threadId: String? = nil,
        conflict: ConflictStrategy? = nil,
        resolve: ConflictResolver? = nil
    ) {
        self.version = version
        self.threadId = threadId
        self.conflict = conflict
        self.resolve = resolve
    }
}

/// An item paired with its metadata, as returned with `include=metadata`.
public struct ItemWithMetadata: Codable, Sendable, Hashable {
    public let item: Item
    public let metadata: Metadata
}

// MARK: - Wire response wrappers

/// Single item response: `{ "item": ..., "metadata": ... }`.
struct ItemResponse: Codable, Sendable {
    var item: Item
    var metadata: Metadata?
}

/// Body for POST /items/:id/transition.
struct TransitionBody: Codable, Sendable {
    let state: String
}

/// Response from GET /items/:id/versions.
struct VersionsResponse: Codable, Sendable {
    let versions: [Version]
}
