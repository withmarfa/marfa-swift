import Foundation

/// Credential lifecycle namespace.
///
/// `system.credential` items are still managed via ``ItemsNamespace`` for
/// generic CRUD; this namespace adds the two creation factories that
/// produce credentials of `oauth_token` and `api_token` kinds. The
/// resulting credential id is passed as `credentialRef` on
/// ``ConnectionsNamespace/install(_:)`` so multiple integrations of the
/// same upstream share one credential row.
///
/// Both creation routes are space-admin gated server-side.
///
/// Available in remote and synced modes. In **pure-local mode** every
/// method throws ``LocalModeUnsupportedError``.
public struct CredentialsNamespace: Sendable {

    let transport: any Transport
    let isLocalMode: Bool

    init(transport: any Transport, isLocalMode: Bool) {
        self.transport = transport
        self.isLocalMode = isLocalMode
    }

    private func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Creates an OAuth provider credential. `POST /credentials/oauth-provider`.
    ///
    /// Resulting credential id is passed as `credentialRef` on
    /// ``ConnectionsNamespace/install(_:)`` for OAuth-based integrations
    /// (e.g. `google.calendar`, `google.tasks`, `google.drive`,
    /// `google.contacts`, `google.gmail`, `google.youtube` — all sharing
    /// one Google OAuth provider row).
    ///
    /// Space-admin only.
    public func createOAuthProvider(
        _ input: CreateOAuthProviderCredentialInput
    ) async throws -> CreatedCredential {
        try ensureRemote("credentials.createOAuthProvider")
        return try await transport.request(
            method: .post,
            path: "/credentials/oauth-provider",
            body: input,
            query: nil
        )
    }

    /// Creates an API-token credential. `POST /credentials/api-token`.
    ///
    /// Resulting credential id is passed as `credentialRef` on
    /// ``ConnectionsNamespace/install(_:)`` for token-based integrations
    /// (Todoist, Readwise, Raindrop). The proxy stamps the
    /// `authScheme`-controlled `Authorization` header on every outbound
    /// call.
    ///
    /// Space-admin only.
    public func createApiToken(
        _ input: CreateApiTokenCredentialInput
    ) async throws -> CreatedCredential {
        try ensureRemote("credentials.createApiToken")
        return try await transport.request(
            method: .post,
            path: "/credentials/api-token",
            body: input,
            query: nil
        )
    }
}
