import Foundation

/// Operator-level admin surface. Backs the `my admin` CLI command tree.
/// Every method requires a platform-admin key (`is_platform: true`);
/// non-platform credentials receive a `403 forbidden` — CLI/UI layers
/// should render `"this command requires a platform-admin key"`.
///
/// A client created via ``MarfaClient/local(path:)`` has no live server;
/// every method here throws ``LocalModeUnsupportedError``.
public struct AdminNamespace: Sendable {

    let transport: any Transport

    /// `true` when this namespace is attached to a pure-local client.
    let isLocalMode: Bool

    fileprivate func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Per-tenant operator surface — listings, status flips, metrics,
    /// and key listings. Mirrors the `/admin/tenants/...` route family.
    /// Tenant quota read/write lives on ``MarfaClient/tenants`` (the
    /// `client.tenants.quotas.*` surface) rather than here; that endpoint
    /// is already platform-admin-gated and exposing it twice would
    /// duplicate the operator surface.
    public var tenants: AdminTenantsNamespace {
        AdminTenantsNamespace(transport: transport, isLocalMode: isLocalMode)
    }

    /// Account-deletion operator controls. Exposes
    /// ``AdminAccountDeletionNamespace/purgeNow()`` for one-shot sweeper
    /// runs.
    public var accountDeletion: AdminAccountDeletionNamespace {
        AdminAccountDeletionNamespace(transport: transport, isLocalMode: isLocalMode)
    }
}

// MARK: - Tenants

/// Per-tenant operator-surface for platform admins.
public struct AdminTenantsNamespace: Sendable {

    let transport: any Transport
    let isLocalMode: Bool

    private func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Lists every tenant in the instance with current operator-status.
    /// Platform-admin only.
    public func list() async throws -> [TenantSummary] {
        try ensureRemote("admin.tenants.list")
        let response: TenantListResponse = try await transport.request(
            method: .get, path: "/admin/tenants", body: nil, query: nil
        )
        return response.data
    }

    /// Single tenant + per-tenant quota overrides + the most-recent
    /// `system.activity` items for the tenant. `quotas` is `nil` when no
    /// override is configured (env defaults apply per-field). Platform-
    /// admin only.
    public func get(id: String) async throws -> TenantDetail {
        try ensureRemote("admin.tenants.get")
        return try await transport.request(
            method: .get,
            path: "/admin/tenants/\(id)",
            body: nil,
            query: nil
        )
    }

    /// Flip the tenant's status to `suspended`. Future non-GET requests
    /// from credentials in the tenant return HTTP 403 `tenant_suspended`;
    /// reads pass through; platform-admin keys bypass. Idempotent.
    public func suspend(id: String) async throws -> TenantSummary {
        try ensureRemote("admin.tenants.suspend")
        return try await transport.request(
            method: .post,
            path: "/admin/tenants/\(id)/suspend",
            body: nil,
            query: nil
        )
    }

    /// Reverse of ``suspend(id:)``. Idempotent.
    public func unsuspend(id: String) async throws -> TenantSummary {
        try ensureRemote("admin.tenants.unsuspend")
        return try await transport.request(
            method: .post,
            path: "/admin/tenants/\(id)/unsuspend",
            body: nil,
            query: nil
        )
    }

    /// Per-tenant usage snapshot — item count by state, blob count and
    /// total bytes, plus recent activity. Platform-admin only.
    public func metrics(id: String) async throws -> TenantMetrics {
        try ensureRemote("admin.tenants.metrics")
        return try await transport.request(
            method: .get,
            path: "/admin/tenants/\(id)/metrics",
            body: nil,
            query: nil
        )
    }

    /// Active (non-revoked) API-key listing for the named tenant.
    /// Operator surface for emergency revocation — pair with
    /// ``KeysNamespace/revoke(id:)``. Platform-admin only.
    public func keys(id: String) async throws -> [TenantApiKeySummary] {
        try ensureRemote("admin.tenants.keys")
        let response: TenantApiKeysResponse = try await transport.request(
            method: .get,
            path: "/admin/tenants/\(id)/keys",
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
    /// does not bypass the grace window. Platform-admin only.
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

/// One tenant in the operator listing.
public struct TenantSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    public let createdAt: String
    public let status: TenantStatus

    public init(id: String, name: String?, createdAt: String, status: TenantStatus) {
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

/// Bounded status enum for tenants. Mirrors the server's
/// `status: 'active' | 'suspended'` discriminator.
public enum TenantStatus: String, Codable, Sendable, Hashable {
    case active
    case suspended
}

/// Composite "show one tenant" response — tenant row + optional quota
/// override + most-recent activity.
public struct TenantDetail: Codable, Sendable {
    public let tenant: TenantSummary
    public let quotas: TenantQuota?
    public let recentActivity: [TenantActivityEntry]

    public init(
        tenant: TenantSummary,
        quotas: TenantQuota?,
        recentActivity: [TenantActivityEntry]
    ) {
        self.tenant = tenant
        self.quotas = quotas
        self.recentActivity = recentActivity
    }

    enum CodingKeys: String, CodingKey {
        case tenant, quotas
        case recentActivity = "recent_activity"
    }
}

/// One `system.activity` entry surfaced through the admin reads.
public struct TenantActivityEntry: Codable, Sendable, Hashable {
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

/// Per-tenant usage snapshot — item / blob counts and a recent-activity
/// tail. Returned by ``AdminTenantsNamespace/metrics(id:)``.
public struct TenantMetrics: Codable, Sendable {
    public let tenantId: String
    public let items: TenantItemCounts
    public let blobs: TenantBlobCounts
    public let recentActivity: [TenantActivityEntry]
    public let generatedAt: String

    public init(
        tenantId: String,
        items: TenantItemCounts,
        blobs: TenantBlobCounts,
        recentActivity: [TenantActivityEntry],
        generatedAt: String
    ) {
        self.tenantId = tenantId
        self.items = items
        self.blobs = blobs
        self.recentActivity = recentActivity
        self.generatedAt = generatedAt
    }

    enum CodingKeys: String, CodingKey {
        case items, blobs
        case tenantId = "tenant_id"
        case recentActivity = "recent_activity"
        case generatedAt = "generated_at"
    }
}

public struct TenantItemCounts: Codable, Sendable, Hashable {
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

public struct TenantBlobCounts: Codable, Sendable, Hashable {
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

/// One active key in the operator-facing tenant-keys listing.
public struct TenantApiKeySummary: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let source: String
    public let role: String
    public let isPlatform: Bool
    public let createdAt: String
    public let lastUsedAt: String?

    public init(
        id: String,
        label: String,
        source: String,
        role: String,
        isPlatform: Bool,
        createdAt: String,
        lastUsedAt: String?
    ) {
        self.id = id
        self.label = label
        self.source = source
        self.role = role
        self.isPlatform = isPlatform
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, label, source, role
        case isPlatform = "is_platform"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }
}

/// Result of ``AdminAccountDeletionNamespace/purgeNow()``.
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

// MARK: - Internal response envelopes

struct TenantListResponse: Codable, Sendable {
    let data: [TenantSummary]
}

struct TenantApiKeysResponse: Codable, Sendable {
    let data: [TenantApiKeySummary]
}

