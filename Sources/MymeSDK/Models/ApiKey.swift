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

/// Input for creating an API key.
public struct CreateKeyInput: Codable, Sendable {
    public var label: String
    public var role: KeyRole?
    public var typePermissions: [String: TypePermission]?
    public var extensionPermissions: [String: ExtensionPermission]?

    public init(
        label: String,
        role: KeyRole? = nil,
        typePermissions: [String: TypePermission]? = nil,
        extensionPermissions: [String: ExtensionPermission]? = nil
    ) {
        self.label = label
        self.role = role
        self.typePermissions = typePermissions
        self.extensionPermissions = extensionPermissions
    }

    enum CodingKeys: String, CodingKey {
        case label, role
        case typePermissions = "type_permissions"
        case extensionPermissions = "extension_permissions"
    }
}

/// API key role.
public enum KeyRole: String, Codable, Sendable {
    case admin
    case member
}

/// Permission level for a type.
public enum TypePermission: String, Codable, Sendable {
    case read
    case write
    case none
}

/// Permission level for an extension namespace.
public enum ExtensionPermission: String, Codable, Sendable {
    case read
    case write
}

