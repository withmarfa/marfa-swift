import Foundation

/// A historical version of an item's properties.
public struct Version: Codable, Sendable, Hashable {
    public let id: String
    public let itemId: String
    public let version: Int
    public let properties: [String: JSONValue]
    public let snapshot: Bool?
    public let createdAt: String
    public let deviceId: String?

    enum CodingKeys: String, CodingKey {
        case id, version, properties, snapshot
        case itemId = "item_id"
        case createdAt = "created_at"
        case deviceId = "device_id"
    }
}
