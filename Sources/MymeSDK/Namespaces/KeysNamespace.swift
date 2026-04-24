import Foundation

/// Keys API namespace. Manages API key creation, listing, and revocation.
///
/// A client created via ``MymeClient/local(path:)`` has no live server;
/// every method here throws ``LocalModeUnsupportedError``.
public struct KeysNamespace: Sendable {

    let transport: any Transport

    /// `true` when this namespace is attached to a pure-local client. When
    /// set, every method throws before touching the transport.
    let isLocalMode: Bool

    private func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Creates a new API key. The raw key value is only available in the response.
    public func create(_ input: CreateKeyInput) async throws -> CreatedKey {
        try ensureRemote("keys.create")
        return try await transport.request(
            method: .post, path: "/keys", body: input, query: nil
        )
    }

    /// Lists all API keys (admin only). Raw key values are not included.
    public func list() async throws -> [ApiKey] {
        try ensureRemote("keys.list")
        let response: KeysListResponse = try await transport.request(
            method: .get, path: "/keys", body: nil, query: nil
        )
        return response.keys
    }

    /// Revokes an API key (admin only).
    public func revoke(id: String) async throws {
        try ensureRemote("keys.revoke")
        let _: EmptyResponse = try await transport.request(
            method: .delete, path: "/keys/\(id)", body: nil, query: nil
        )
    }
}
