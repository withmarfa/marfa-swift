import Foundation

/// Typed wrapper for `system.connection` items — an approved relationship
/// between this Myme tenant and an external authority.
///
/// ``kind`` discriminates between three variants:
/// - ``ConnectionKind/app``: an OAuth client this user has authorized
///   (e.g. Notes signing in via the Authorization Code + PKCE flow).
/// - ``ConnectionKind/integration``: a hosted or local connector that
///   reads or writes Myme on the user's behalf.
/// - ``ConnectionKind/tenant``: cross-tenant access (reserved).
///
/// Lifecycle is bounded to ``ItemState/active`` and ``ItemState/revoked``
/// — there is no archived/trashed state for connections. Pause/resume is
/// represented by the integration-only ``runtimeStatus`` enum, which is
/// server-stamped (no client write path until the runtime executor lands).
///
/// Hand-written rather than generated because the codegen-domain
/// pipeline currently scans only `core.*` types; system types are
/// covered by hand-written domain models on a per-need basis.
public struct Connection: MymeItem {
    public static let typeIdentifier = "system.connection"

    public let item: Item

    // MARK: - Required

    /// Discriminator: which variant of connection this is.
    public var kind: ConnectionKind {
        guard let raw = item.properties["kind"]?.stringValue,
              let value = ConnectionKind(rawValue: raw) else {
            return .integration
        }
        return value
    }

    /// When the grant was approved.
    public var grantedAt: String { item.properties["granted_at"]?.stringValue ?? "" }

    // MARK: - OAuth-only (kind == .app)

    /// OAuth client identifier. Set when ``kind`` is ``ConnectionKind/app``.
    public var clientId: String? { item.properties["client_id"]?.stringValue }

    /// Granted scope strings. Empty array on connections with no scopes.
    public var scopes: [String] {
        item.properties["scopes"]?.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    // MARK: - Integration-only (kind == .integration)

    /// Id of the `system.integration` item this connection implements.
    public var integrationRef: String? { item.properties["integration_ref"]?.stringValue }

    /// Id of the `system.credential` item holding the integration's
    /// runtime API key.
    public var credentialRef: String? { item.properties["credential_ref"]?.stringValue }

    /// Per-Integration JSON config payload (shape determined by the
    /// Integration manifest).
    public var configuration: [String: JSONValue]? {
        item.properties["configuration"]?.dictionaryValue
    }

    /// Read/write/both direction declared by the manifest.
    public var direction: String? { item.properties["direction"]?.stringValue }

    /// Trigger declarations from the manifest (each entry is a
    /// JSON object; shape varies by `type` field).
    public var triggers: [JSONValue] {
        item.properties["triggers"]?.arrayValue ?? []
    }

    /// Id of the `system.device` item when the integration runs on a
    /// specific local device (e.g. a sync-agent host).
    public var attachedDevice: String? { item.properties["attached_device"]?.stringValue }

    /// Operational health, distinct from the universal lifecycle ``state``.
    /// Server-stamped only — no client write surface.
    public var runtimeStatus: String? { item.properties["runtime_status"]?.stringValue }

    /// Last successful sync run timestamp.
    public var lastSyncAt: String? { item.properties["last_sync_at"]?.stringValue }

    /// Next scheduled run, when applicable.
    public var nextRunAt: String? { item.properties["next_run_at"]?.stringValue }

    /// Most recent failure timestamp (cleared on next success).
    public var lastErrorAt: String? { item.properties["last_error_at"]?.stringValue }

    /// When `true`, system.activity items emitted by this integration are
    /// server-stamped `tier:'feed'`.
    public var feedActivity: Bool? { item.properties["feed_activity"]?.boolValue }

    // MARK: - Universal optional

    /// Most recent successful use of any token issued under this grant.
    public var lastUsedAt: String? { item.properties["last_used_at"]?.stringValue }

    /// When the grant was revoked, if any.
    public var revokedAt: String? { item.properties["revoked_at"]?.stringValue }

    // MARK: - Init

    public init?(from item: Item) {
        guard item.type == Self.typeIdentifier else { return nil }
        guard item.properties["kind"]?.stringValue != nil else { return nil }
        guard item.properties["granted_at"]?.stringValue != nil else { return nil }
        self.item = item
    }

    public func toProperties() -> [String: JSONValue] {
        // Pass-through round-trip: callers who need to mutate a typed
        // Connection should reach for client.items.update on the underlying
        // Item directly. Returning the existing properties dictionary
        // preserves any fields this typed wrapper does not surface.
        item.properties
    }
}

