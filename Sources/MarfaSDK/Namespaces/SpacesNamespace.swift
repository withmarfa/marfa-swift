import Foundation

/// Space-scoped configuration and quotas. Mirrors the TS SDK's
/// `client.spaces.*` surface — the SDK exposes one spaces surface and the
/// server gates each method on the permission it needs.
///
/// Routes:
/// - `GET /spaces/me/config` — `space.settings`
/// - `PUT /spaces/me/config` — `space.settings`
/// - `GET /spaces/me/quotas` — `space.usage`
/// - `GET /spaces/{id}/quotas` — the operator key only
/// - `PUT /spaces/{id}/quotas` — the operator key only
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
    /// Needs `space.settings`.
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
    /// Needs `space.settings`.
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

    /// Per-space quota read and write. A credential holding `space.usage`
    /// reads its own row via ``SpaceQuotasNamespace/getOwn()``; naming a
    /// space by id is cross-space authority and takes the operator key.
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
    /// configured. Needs `space.usage`.
    ///
    /// The operator key holds no space, so it receives `400` here — use
    /// ``getById(_:)`` with an explicit id instead.
    public func getOwn() async throws -> SpaceQuota {
        try ensureRemote("spaces.quotas.getOwn")
        return try await transport.request(
            method: .get,
            path: "/spaces/me/quotas",
            body: nil,
            query: nil
        )
    }

    /// Reads a specific space's quota row. The operator key only.
    public func getById(_ spaceId: String) async throws -> SpaceQuota {
        try ensureRemote("spaces.quotas.getById")
        return try await transport.request(
            method: .get,
            path: "/spaces/\(spaceId.escapedPathSegment)/quotas",
            body: nil,
            query: nil
        )
    }

    /// Sets per-space quota overrides. Each field is independent — a
    /// supplied non-`nil` value overrides the env default; an explicit
    /// `nil` resets that field to the env default. Field omission
    /// leaves the existing override untouched. The operator key only.
    @discardableResult
    public func set(_ spaceId: String, _ input: SpaceQuotaInput) async throws -> SpaceQuota {
        try ensureRemote("spaces.quotas.set")
        return try await transport.request(
            method: .put,
            path: "/spaces/\(spaceId.escapedPathSegment)/quotas",
            body: input,
            query: nil
        )
    }
}
