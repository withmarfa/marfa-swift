import Foundation

/// Keys API namespace. Manages API key creation, listing, and revocation.
public struct KeysNamespace: Sendable {

    let transport: any Transport

    /// Creates a new API key. The raw key value is only available in the response.
    public func create(_ input: CreateKeyInput) async throws -> CreatedKey {
        try await transport.request(
            method: .post, path: "/keys", body: input, query: nil
        )
    }

    /// Lists all API keys (admin only). Raw key values are not included.
    public func list() async throws -> [ApiKey] {
        let response: KeysListResponse = try await transport.request(
            method: .get, path: "/keys", body: nil, query: nil
        )
        return response.keys
    }

    /// Revokes an API key (admin only).
    public func revoke(id: String) async throws {
        let _: EmptyResponse = try await transport.request(
            method: .delete, path: "/keys/\(id)", body: nil, query: nil
        )
    }
}
