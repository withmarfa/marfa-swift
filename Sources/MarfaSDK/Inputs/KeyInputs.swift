import Foundation

/// Input for creating an API key.
public struct CreateKeyInput: Codable, Sendable {
    public var label: String
    /// Where the key came from, as free text the operator surface shows
    /// beside it. **Required by the server**, and it has no default here on
    /// purpose: it is provenance, so a value this kit chose would be a
    /// claim the caller never made and the server would show it as if they
    /// had. Prefixes that name a connection's own integration credential
    /// are reserved and refused.
    public var source: String
    /// The space permissions the key holds, named one by one.
    ///
    /// Absent takes the creator's whole set, and anything named is clamped to
    /// what the creator holds — so a mint can narrow and can never widen. An
    /// empty array is a key with no administrative reach at all, which is a
    /// different thing from absent and is what a key handed to an app usually
    /// wants.
    public var spacePermissions: [SpacePermission]?
    public var typePermissions: [String: TypePermission]?
    public var extensionPermissions: [String: ExtensionPermission]?
    /// Per-edge-type access. Absent leaves the server's default, which is
    /// none: edge access is opt-in and a key that says nothing gets nothing.
    public var edgePermissions: [String: EdgePermission]?
    /// Per-sub-resource metadata access, keyed by `types` or `edge_types`.
    /// Absent leaves the server's default, which is likewise none.
    public var metadataPermissions: [String: MetadataPermission]?
    /// Per-row access to the account-holder profile, keyed by the row name.
    /// Absent leaves the server's default, which is likewise none.
    public var profilePermissions: [String: ProfilePermission]?

    public init(
        label: String,
        source: String,
        spacePermissions: [SpacePermission]? = nil,
        typePermissions: [String: TypePermission]? = nil,
        extensionPermissions: [String: ExtensionPermission]? = nil,
        edgePermissions: [String: EdgePermission]? = nil,
        metadataPermissions: [String: MetadataPermission]? = nil,
        profilePermissions: [String: ProfilePermission]? = nil
    ) {
        self.label = label
        self.source = source
        self.spacePermissions = spacePermissions
        self.typePermissions = typePermissions
        self.extensionPermissions = extensionPermissions
        self.edgePermissions = edgePermissions
        self.metadataPermissions = metadataPermissions
        self.profilePermissions = profilePermissions
    }

    enum CodingKeys: String, CodingKey {
        case label, source
        case spacePermissions = "space_permissions"
        case typePermissions = "type_permissions"
        case extensionPermissions = "extension_permissions"
        case edgePermissions = "edge_permissions"
        case metadataPermissions = "metadata_permissions"
        case profilePermissions = "profile_permissions"
    }
}

/// One administrative surface of a space, granted by being named and by
/// nothing else.
///
/// **There is no rank above these and no wildcard across them.** A credential
/// holds the ones it was given, every door checks the set rather than who the
/// caller is, and a content permission says nothing about any of them. The
/// closed set is the point: a consent screen has to read them as sentences,
/// so each names a surface a person would recognise rather than a route.
///
/// Running the instance is not in here. That is the operator key, which holds
/// no space and no permissions because it is fenced outside the model rather
/// than expressed as a full set inside it.
///
/// No case for the retired `capability.*` spelling, and none for the roles
/// that preceded it. Carrying either would keep a retired word decoding
/// indefinitely and hide a server nobody upgraded.
public enum SpacePermission: String, Codable, Sendable {
    case webhooks = "space.webhooks"
    case connections = "space.connections"
    case schema = "space.schema"
    case usage = "space.usage"
    case settings = "space.settings"
    case auditRead = "space.audit_read"
    case itemPurge = "space.item_purge"
    case upstreamAccess = "space.upstream_access"
    case credentials = "space.credentials"
    case keys = "space.keys"
    case appGrants = "space.app_grants"
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

/// Permission level for one row of the account-holder profile.
public enum ProfilePermission: String, Codable, Sendable {
    case read
    case write
}
