import Foundation

/// Tenant-scoped configuration and quotas. Mirrors the TS SDK's
/// `client.tenants.*` surface — the SDK exposes one tenants surface; the
/// server gates each method by role (tenant-admin vs platform-admin).
///
/// Routes:
/// - `GET /tenants/current/config` — tenant-admin (or platform-admin)
/// - `PUT /tenants/current/config` — tenant-admin (or platform-admin)
/// - `GET /tenants/me/quotas` — tenant-admin (or platform-admin)
/// - `GET /tenants/{id}/quotas` — platform-admin only
/// - `PUT /tenants/{id}/quotas` — platform-admin only
///
/// A client created via ``MarfaClient/local(path:)`` has no live server;
/// every method here throws ``LocalModeUnsupportedError``.
public struct TenantsNamespace: Sendable {

    let transport: any Transport

    /// `true` when this namespace is attached to a pure-local client.
    let isLocalMode: Bool

    fileprivate func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Reads the calling tenant's configuration. Returns an empty
    /// ``TenantConfig`` value when no overrides have been written.
    /// Tenant-admin or platform-admin.
    public func getConfig() async throws -> TenantConfig {
        try ensureRemote("tenants.getConfig")
        return try await transport.request(
            method: .get,
            path: "/tenants/current/config",
            body: nil,
            query: nil
        )
    }

    /// Replaces the calling tenant's configuration. PUT semantics — every
    /// field absent from ``config`` reverts to the env default.
    /// Tenant-admin or platform-admin.
    @discardableResult
    public func setConfig(_ config: TenantConfig) async throws -> TenantConfig {
        try ensureRemote("tenants.setConfig")
        return try await transport.request(
            method: .put,
            path: "/tenants/current/config",
            body: config,
            query: nil
        )
    }

    /// Per-tenant quota read/write. Tenant-admin can read their own
    /// row via ``TenantQuotasNamespace/getOwn()``; reads and writes
    /// targeting a specific tenant by id require platform-admin.
    public var quotas: TenantQuotasNamespace {
        TenantQuotasNamespace(transport: transport, isLocalMode: isLocalMode)
    }
}

// MARK: - Quotas

/// Per-tenant quota ceilings. `nil` fields fall back to the env defaults
/// (`MARFA_DEFAULT_QUOTA_*`).
public struct TenantQuotasNamespace: Sendable {

    let transport: any Transport
    let isLocalMode: Bool

    fileprivate func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Reads the calling tenant's quota row. The server resolves the
    /// tenant from the bearer; the SDK never sends the tenant id on this
    /// path. Returns a row of `nil` fields when no override is
    /// configured. Tenant-admin (or platform-admin with a
    /// tenant-bound key).
    ///
    /// Platform-admin keys with no `tenant_id` receive `400` from the
    /// server — use ``getById(_:)`` with an explicit id instead.
    public func getOwn() async throws -> TenantQuota {
        try ensureRemote("tenants.quotas.getOwn")
        return try await transport.request(
            method: .get,
            path: "/tenants/me/quotas",
            body: nil,
            query: nil
        )
    }

    /// Reads a specific tenant's quota row. Platform-admin only.
    public func getById(_ tenantId: String) async throws -> TenantQuota {
        try ensureRemote("tenants.quotas.getById")
        return try await transport.request(
            method: .get,
            path: "/tenants/\(tenantId)/quotas",
            body: nil,
            query: nil
        )
    }

    /// Sets per-tenant quota overrides. Each field is independent — a
    /// supplied non-`nil` value overrides the env default; an explicit
    /// `nil` resets that field to the env default. Field omission
    /// leaves the existing override untouched. Platform-admin only.
    @discardableResult
    public func set(_ tenantId: String, _ input: TenantQuotaInput) async throws -> TenantQuota {
        try ensureRemote("tenants.quotas.set")
        return try await transport.request(
            method: .put,
            path: "/tenants/\(tenantId)/quotas",
            body: input,
            query: nil
        )
    }
}
