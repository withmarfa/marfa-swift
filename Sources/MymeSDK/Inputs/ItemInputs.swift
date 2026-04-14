import Foundation

/// Input for creating a new item.
public struct CreateItemInput: Codable, Sendable {
    public var type: String
    public var properties: [String: JSONValue]
    public var id: String?
    public var state: ItemState?
    public var timestamp: String?
    public var source: String?
    public var sourceId: String?
    public var origin: Origin?
    public var device: String?
    public var library: Bool?
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
        origin: Origin? = nil,
        device: String? = nil,
        library: Bool? = nil,
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
        self.device = device
        self.library = library
        self.parentId = parentId
        self.threadId = threadId
        self.captureLatitude = captureLatitude
        self.captureLongitude = captureLongitude
        self.tags = tags
        self.about = about
    }

    enum CodingKeys: String, CodingKey {
        case type, properties, id, state, timestamp, source, origin, device, library, tags, about
        case sourceId = "source_id"
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

/// Body for POST /items/:id/transition.
struct TransitionBody: Codable, Sendable {
    let state: String
}
