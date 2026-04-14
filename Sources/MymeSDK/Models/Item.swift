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
