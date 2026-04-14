import Foundation

/// An API key record (the raw key value is only available at creation time).
public struct ApiKey: Codable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let role: KeyRole
    public let typePermissions: [String: TypePermission]
    public let extensionPermissions: [String: ExtensionPermission]?
    public let createdAt: String
    public let lastUsedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, label, role
        case typePermissions = "type_permissions"
        case extensionPermissions = "extension_permissions"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }
}

/// A newly created API key, including the raw key value (shown only once).
public struct CreatedKey: Codable, Sendable {
    public let id: String
    public let key: String
    public let label: String
    public let role: KeyRole
}
