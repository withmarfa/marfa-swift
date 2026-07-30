import Foundation

/// Space-scoped configuration and quotas. Mirrors the TS SDK's
/// `client.spaces.*` surface — the SDK exposes one spaces surface; the
/// server gates each method by role (space-admin vs platform-admin).
///
/// Routes:
/// - `GET /spaces/me/config` — space-admin (or platform-admin)
/// - `PUT /spaces/me/config` — space-admin (or platform-admin)
/// - `GET /spaces/me/quotas` — space-admin (or platform-admin)
/// - `GET /spaces/{id}/quotas` — platform-admin only
/// - `PUT /spaces/{id}/quotas` — platform-admin only
///
/// A client created via ``MarfaClient/local(path:)`` has no live server;
/// every method here throws ``LocalModeUnsupportedError``.
public struct SpacesNamespace: Sendable {

    let transport: any Transport

    /// `true` when this namespace is attached to a pure-local client.
    let isLocalMode: Bool

    fileprivate func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Reads the calling space's configuration. Returns an empty
    /// ``SpaceConfig`` value when no overrides have been written.
    /// Space-admin or platform-admin.
    public func getConfig() async throws -> SpaceConfig {
        try ensureRemote("spaces.getConfig")
        return try await transport.request(
            method: .get,
            path: "/spaces/me/config",
            body: nil,
            query: nil
        )
    }

    /// Replaces the calling space's configuration. PUT semantics — every
    /// field absent from ``config`` reverts to the env default.
    /// Space-admin or platform-admin.
    @discardableResult
    public func setConfig(_ config: SpaceConfig) async throws -> SpaceConfig {
        try ensureRemote("spaces.setConfig")
        return try await transport.request(
            method: .put,
            path: "/spaces/me/config",
            body: config,
            query: nil
        )
    }

    /// Per-space quota read/write. Space-admin can read their own
    /// row via ``SpaceQuotasNamespace/getOwn()``; reads and writes
    /// targeting a specific space by id require platform-admin.
    public var quotas: SpaceQuotasNamespace {
        SpaceQuotasNamespace(transport: transport, isLocalMode: isLocalMode)
    }
}

// MARK: - Quotas

/// Per-space quota ceilings. `nil` fields fall back to the env defaults
/// (`MARFA_DEFAULT_QUOTA_*`).
public struct SpaceQuotasNamespace: Sendable {

    let transport: any Transport
    let isLocalMode: Bool

    fileprivate func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Reads the calling space's quota row. The server resolves the
    /// space from the bearer; the SDK never sends the space id on this
    /// path. Returns a row of `nil` fields when no override is
    /// configured. Space-admin (or platform-admin with a
    /// space-bound key).
    ///
    /// Platform-admin keys with no `space_id` receive `400` from the
    /// server — use ``getById(_:)`` with an explicit id instead.
    public func getOwn() async throws -> SpaceQuota {
        try ensureRemote("spaces.quotas.getOwn")
        return try await transport.request(
            method: .get,
            path: "/spaces/me/quotas",
            body: nil,
            query: nil
        )
    }

    /// Reads a specific space's quota row. Platform-admin only.
    public func getById(_ spaceId: String) async throws -> SpaceQuota {
        try ensureRemote("spaces.quotas.getById")
        return try await transport.request(
            method: .get,
            path: "/spaces/\(spaceId)/quotas",
            body: nil,
            query: nil
        )
    }

    /// Sets per-space quota overrides. Each field is independent — a
    /// supplied non-`nil` value overrides the env default; an explicit
    /// `nil` resets that field to the env default. Field omission
    /// leaves the existing override untouched. Platform-admin only.
    @discardableResult
    public func set(_ spaceId: String, _ input: SpaceQuotaInput) async throws -> SpaceQuota {
        try ensureRemote("spaces.quotas.set")
        return try await transport.request(
            method: .put,
            path: "/spaces/\(spaceId)/quotas",
            body: input,
            query: nil
        )
    }
}
