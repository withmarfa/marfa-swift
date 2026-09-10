import Foundation

/// The operator surface: the instance routes under `/admin`. Backs the
/// `marfa operator` CLI command tree.
/// Every method requires the operator key (`is_operator: true`, and no
/// space); any other credential receives a `403 forbidden`, and CLI/UI
/// layers should render `"this command requires the operator key"`.
///
/// A client created via ``MarfaClient/local(path:)`` has no live server;
/// every method here throws ``LocalModeUnsupportedError``.
public struct AdminNamespace: Sendable {

    let transport: any Transport
    let isLocalMode: Bool

    fileprivate func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Space quota read/write lives on ``MarfaClient/spaces``
    /// (`client.spaces.quotas.*`), not here.
    public var spaces: AdminSpacesNamespace {
        AdminSpacesNamespace(transport: transport, isLocalMode: isLocalMode)
    }

    public var accountDeletion: AdminAccountDeletionNamespace {
        AdminAccountDeletionNamespace(transport: transport, isLocalMode: isLocalMode)
    }

    /// Platform type rows this instance carries that the running build no
    /// longer ships, and the removal of one.
    public var platformTypes: AdminPlatformTypesNamespace {
        AdminPlatformTypesNamespace(transport: transport, isLocalMode: isLocalMode)
    }
}

// MARK: - Platform types

/// The gap between the types a build ships and the type rows an instance
/// holds. A row is what makes items of that type resolve, so a build that
/// stops shipping a type leaves its rows behind rather than dropping them —
/// a rollback is the ordinary way this happens, where the older build simply
/// does not know about rows the newer one wrote.
///
/// `/health` publishes the count of these and nothing else about them,
/// because it is unauthenticated. This is where the identifiers live.
public struct AdminPlatformTypesNamespace: Sendable {

    let transport: any Transport
    let isLocalMode: Bool

    private func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Every platform type row the running build no longer ships, each with
    /// how many items across every space still carry the identifier, the
    /// types that inherit from it, and whether it can be removed.
    ///
    /// A report rather than a prune. The count is read live rather than from
    /// the boot-time report, because it is the part that changes without a
    /// restart and reasoning about a removal from a stale copy is the
    /// mistake worth avoiding. The operator key only.
    public func drift() async throws -> [DriftedPlatformType] {
        try ensureRemote("admin.platformTypes.drift")
        let response: PlatformTypeDriftResponse = try await transport.request(
            method: .get,
            path: "/admin/platform-types/drift",
            body: nil,
            query: nil
        )
        return response.types
    }

    /// Remove exactly one platform type row this build does not ship.
    ///
    /// Instance-wide and not undoable from here: a build that no longer
    /// ships the type cannot re-seed the row. It is wrapped nonetheless,
    /// where account and space deletion are not, because the server refuses
    /// it in every case where something still depends on it — `409` when the
    /// build still ships the identifier, when items still carry it, or when
    /// another type declares it as a parent, and `404` when no platform row
    /// holds it. It cannot orphan readable data, which is the property that
    /// puts the two deletions out of reach and this within it.
    ///
    /// The type keeps resolving until the next restart, since the in-memory
    /// registry is filled from the rows at boot.
    ///
    /// Returns nothing: the route's body carries a constant `true` and an
    /// echo of `id`, so a caller learns nothing from it that it did not
    /// already have. What it needs to know arrives as a thrown error.
    /// The operator key only.
    public func remove(_ id: String) async throws {
        try ensureRemote("admin.platformTypes.remove")
        let _: EmptyResponse = try await transport.request(
            method: .post,
            path: "/admin/platform-types/\(id.escapedPathSegment)/remove",
            body: nil,
            query: nil
        )
    }
}

// MARK: - Spaces

/// Per-space operator surface, reached with the operator key.
public struct AdminSpacesNamespace: Sendable {

    let transport: any Transport
    let isLocalMode: Bool

    private func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    public func list() async throws -> [SpaceSummary] {
        try ensureRemote("admin.spaces.list")
        let response: SpaceListResponse = try await transport.request(
            method: .get, path: "/admin/spaces", body: nil, query: nil
        )
        return response.data
    }

    /// Single space + per-space quota overrides + the most-recent
    /// `system.activity` items for the space. `quotas` is `nil` when no
    /// override is configured (env defaults apply per-field). Platform-
    /// admin only.
    public func get(id: String) async throws -> SpaceDetail {
        try ensureRemote("admin.spaces.get")
        return try await transport.request(
            method: .get,
            path: "/admin/spaces/\(id.escapedPathSegment)",
            body: nil,
            query: nil
        )
    }

    /// Flip the space's status to `suspended`. Future non-GET requests
    /// from credentials in the space return HTTP 403 `space_suspended`;
    /// reads pass through; the operator key is not suspended. Idempotent.
    public func suspend(id: String) async throws -> SpaceSummary {
        try ensureRemote("admin.spaces.suspend")
        return try await transport.request(
            method: .post,
            path: "/admin/spaces/\(id.escapedPathSegment)/suspend",
            body: nil,
            query: nil
        )
    }

    /// Reverse of ``suspend(id:)``. Idempotent.
    public func unsuspend(id: String) async throws -> SpaceSummary {
        try ensureRemote("admin.spaces.unsuspend")
        return try await transport.request(
            method: .post,
            path: "/admin/spaces/\(id.escapedPathSegment)/unsuspend",
            body: nil,
            query: nil
        )
    }

    public func metrics(id: String) async throws -> SpaceMetrics {
        try ensureRemote("admin.spaces.metrics")
        return try await transport.request(
            method: .get,
            path: "/admin/spaces/\(id.escapedPathSegment)/metrics",
            body: nil,
            query: nil
        )
    }

    /// Active (non-revoked) API-key listing for the named space.
    /// Pair with ``KeysNamespace/revoke(id:)`` for emergency revocation.
    public func keys(id: String) async throws -> [SpaceApiKeySummary] {
        try ensureRemote("admin.spaces.keys")
        let response: SpaceApiKeysResponse = try await transport.request(
            method: .get,
            path: "/admin/spaces/\(id.escapedPathSegment)/keys",
            body: nil,
            query: nil
        )
        return response.data
    }

}

// MARK: - Account deletion

/// Operator controls for the account-deletion lifecycle.
public struct AdminAccountDeletionNamespace: Sendable {

    let transport: any Transport
    let isLocalMode: Bool

    private func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Force a one-shot run of the pending-delete purger. Returns the
    /// number of accounts purged this tick. Useful when an account has
    /// just passed its grace window and the operator does not want to
    /// wait for the next scheduled sweep (default cadence: 1 hour).
    ///
    /// Idempotent — re-running with no eligible rows returns 0. Only
    /// sweeps accounts already past `pending_deletion_at + grace_days`;
    /// does not bypass the grace window. The operator key only.
    @discardableResult
    public func purgeNow() async throws -> PurgeNowResult {
        try ensureRemote("admin.accountDeletion.purgeNow")
        return try await transport.request(
            method: .post,
            path: "/admin/account-deletion/purge-now",
            body: nil,
            query: nil
        )
    }
}

// MARK: - Wire-adjacent input/output shapes

public struct SpaceSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    public let createdAt: String
    public let status: SpaceStatus

    public init(id: String, name: String?, createdAt: String, status: SpaceStatus) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case createdAt = "created_at"
    }
}

/// Bounded status enum for spaces. Mirrors the server's
/// `status: 'active' | 'suspended'` discriminator.
public enum SpaceStatus: String, Codable, Sendable, Hashable {
    case active
    case suspended
}

public struct SpaceDetail: Codable, Sendable {
    public let space: SpaceSummary
    public let quotas: SpaceQuota?
    public let recentActivity: [SpaceActivityEntry]

    public init(
        space: SpaceSummary,
        quotas: SpaceQuota?,
        recentActivity: [SpaceActivityEntry]
    ) {
        self.space = space
        self.quotas = quotas
        self.recentActivity = recentActivity
    }

    enum CodingKeys: String, CodingKey {
        case space, quotas
        case recentActivity = "recent_activity"
    }
}

public struct SpaceActivityEntry: Codable, Sendable, Hashable {
    public let id: String
    public let severity: String
    public let summary: String
    public let createdAt: String

    public init(id: String, severity: String, summary: String, createdAt: String) {
        self.id = id
        self.severity = severity
        self.summary = summary
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, severity, summary
        case createdAt = "created_at"
    }
}

public struct SpaceMetrics: Codable, Sendable {
    public let spaceId: String
    public let items: SpaceItemCounts
    public let blobs: SpaceBlobCounts
    public let recentActivity: [SpaceActivityEntry]
    public let generatedAt: String

    public init(
        spaceId: String,
        items: SpaceItemCounts,
        blobs: SpaceBlobCounts,
        recentActivity: [SpaceActivityEntry],
        generatedAt: String
    ) {
        self.spaceId = spaceId
        self.items = items
        self.blobs = blobs
        self.recentActivity = recentActivity
        self.generatedAt = generatedAt
    }

    enum CodingKeys: String, CodingKey {
        case items, blobs
        case spaceId = "space_id"
        case recentActivity = "recent_activity"
        case generatedAt = "generated_at"
    }
}

public struct SpaceItemCounts: Codable, Sendable, Hashable {
    public let total: Int
    public let active: Int
    public let archived: Int
    public let trashed: Int

    public init(total: Int, active: Int, archived: Int, trashed: Int) {
        self.total = total
        self.active = active
        self.archived = archived
        self.trashed = trashed
    }
}

public struct SpaceBlobCounts: Codable, Sendable, Hashable {
    public let count: Int
    public let totalSize: Int

    public init(count: Int, totalSize: Int) {
        self.count = count
        self.totalSize = totalSize
    }

    enum CodingKeys: String, CodingKey {
        case count
        case totalSize = "total_size"
    }
}

public struct SpaceApiKeySummary: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let source: String
    /// The administrative surfaces this key reaches inside its space.
    ///
    /// Empty is an ordinary content credential, which is most of them. It is
    /// the whole of what the key may do beyond its content maps: there is no
    /// rank above it and nothing else a door consults.
    public let spacePermissions: [String]
    /// Whether this is the operator key.
    ///
    /// Never true in a space's listing, because the operator key holds no
    /// space — it runs the instance and is fenced outside the permission
    /// model rather than sitting at the top of it. The field is here because
    /// the server sends it, not because a space can contain one.
    public let isOperator: Bool
    public let createdAt: String
    public let lastUsedAt: String?

    public init(
        id: String,
        label: String,
        source: String,
        spacePermissions: [String],
        isOperator: Bool,
        createdAt: String,
        lastUsedAt: String?
    ) {
        self.id = id
        self.label = label
        self.source = source
        self.spacePermissions = spacePermissions
        self.isOperator = isOperator
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, label, source
        case spacePermissions = "space_permissions"
        case isOperator = "is_operator"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }
}

public struct PurgeNowResult: Codable, Sendable, Hashable {
    public let purgedCount: Int
    public let runAt: String

    public init(purgedCount: Int, runAt: String) {
        self.purgedCount = purgedCount
        self.runAt = runAt
    }

    enum CodingKeys: String, CodingKey {
        case purgedCount = "purged_count"
        case runAt = "run_at"
    }
}

// MARK: - Internal response envelopes (unwrapped by namespace methods above)

struct SpaceListResponse: Codable, Sendable {
    let data: [SpaceSummary]
}

struct SpaceApiKeysResponse: Codable, Sendable {
    let data: [SpaceApiKeySummary]
}

struct PlatformTypeDriftResponse: Codable, Sendable {
    let types: [DriftedPlatformType]
}

