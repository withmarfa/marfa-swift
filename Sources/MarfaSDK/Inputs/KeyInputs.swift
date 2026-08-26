import Foundation

/// Input for creating an API key.
public struct CreateKeyInput: Codable, Sendable {
    public var label: String
    public var role: KeyRole?
    public var typePermissions: [String: TypePermission]?
    public var extensionPermissions: [String: ExtensionPermission]?
    /// Per-edge-type access. Absent leaves the server's default, which is
    /// none: edge access is opt-in and a key that says nothing gets nothing.
    public var edgePermissions: [String: EdgePermission]?
    /// Per-sub-resource metadata access, keyed by `types` or `edge_types`.
    /// Absent leaves the server's default, which is likewise none.
    public var metadataPermissions: [String: MetadataPermission]?

    public init(
        label: String,
        role: KeyRole? = nil,
        typePermissions: [String: TypePermission]? = nil,
        extensionPermissions: [String: ExtensionPermission]? = nil,
        edgePermissions: [String: EdgePermission]? = nil,
        metadataPermissions: [String: MetadataPermission]? = nil
    ) {
        self.label = label
        self.role = role
        self.typePermissions = typePermissions
        self.extensionPermissions = extensionPermissions
        self.edgePermissions = edgePermissions
        self.metadataPermissions = metadataPermissions
    }

    enum CodingKeys: String, CodingKey {
        case label, role
        case typePermissions = "type_permissions"
        case extensionPermissions = "extension_permissions"
        case edgePermissions = "edge_permissions"
        case metadataPermissions = "metadata_permissions"
    }
}

/// API key role.
public enum KeyRole: String, Codable, Sendable {
    case admin
    case spaceAdmin = "space_admin"
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

/// Permission level for an edge type.
public enum EdgePermission: String, Codable, Sendable {
    case read
    case write
}

/// Permission level for metadata access on a key.
public enum MetadataPermission: String, Codable, Sendable {
    case read
    case write
}
