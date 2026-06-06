import Foundation

/// Input for creating an OAuth provider credential.
///
/// `POST /credentials/oauth-provider`. Creates a `system.credential` of
/// kind `oauth_token` carrying an upstream service's OAuth client config —
/// authorize URL, token URL, client_id, encrypted client_secret, upstream
/// API base URL, and optional default scope. The resulting credential id is
/// passed as `credential_ref` on subsequent ``ConnectionsNamespace/install(_:)``
/// calls so multiple integrations of the same upstream (e.g. `google.calendar`
/// + `google.tasks`) share one OAuth client and one stored secret instead of
/// duplicating per-integration.
///
/// The client_secret is encrypted server-side under the
/// `connectionOauthToken` HKDF domain (AES-256-GCM). Decryption only
/// happens at the OAuth proxy + callback paths; the plaintext is never
/// returned by any read path.
///
/// Tenant-admin only.
public struct CreateOAuthProviderCredentialInput: Codable, Sendable, Hashable {
    public var label: String
    public var oauthAuthorizeUrl: String
    public var oauthTokenUrl: String
    public var oauthClientId: String
    public var oauthClientSecret: String
    public var upstreamBaseUrl: String
    public var oauthDefaultScope: String?

    public init(
        label: String,
        oauthAuthorizeUrl: String,
        oauthTokenUrl: String,
        oauthClientId: String,
        oauthClientSecret: String,
        upstreamBaseUrl: String,
        oauthDefaultScope: String? = nil
    ) {
        self.label = label
        self.oauthAuthorizeUrl = oauthAuthorizeUrl
        self.oauthTokenUrl = oauthTokenUrl
        self.oauthClientId = oauthClientId
        self.oauthClientSecret = oauthClientSecret
        self.upstreamBaseUrl = upstreamBaseUrl
        self.oauthDefaultScope = oauthDefaultScope
    }

    enum CodingKeys: String, CodingKey {
        case label
        case oauthAuthorizeUrl = "oauth_authorize_url"
        case oauthTokenUrl = "oauth_token_url"
        case oauthClientId = "oauth_client_id"
        case oauthClientSecret = "oauth_client_secret"
        case upstreamBaseUrl = "upstream_base_url"
        case oauthDefaultScope = "oauth_default_scope"
    }
}

/// Input for creating an API-token credential.
///
/// `POST /credentials/api-token`. Creates a `system.credential` of kind
/// `api_token` carrying a static upstream bearer credential. The
/// `upstreamBaseUrl` is the Marfa proxy's target; the `apiToken` is
/// encrypted server-side and decrypted only at the proxy gate.
///
/// `authScheme` controls the header the proxy stamps on outbound calls:
/// - `.bearer` (default) → `Authorization: Bearer <token>`
/// - `.token` → `Authorization: Token <token>` (Readwise, GitHub PATs)
/// - `.basic` → `Authorization: Basic <token>` (pre-encoded by the
///   caller)
///
/// Returned credential id is used as `credential_ref` on
/// ``ConnectionsNamespace/install(_:)`` for token-based integrations
/// (Todoist, Readwise, Raindrop). Tenant-admin only.
public struct CreateApiTokenCredentialInput: Codable, Sendable, Hashable {
    public var label: String
    public var upstreamBaseUrl: String
    public var apiToken: String
    public var authScheme: AuthScheme?

    public init(
        label: String,
        upstreamBaseUrl: String,
        apiToken: String,
        authScheme: AuthScheme? = nil
    ) {
        self.label = label
        self.upstreamBaseUrl = upstreamBaseUrl
        self.apiToken = apiToken
        self.authScheme = authScheme
    }

    enum CodingKeys: String, CodingKey {
        case label
        case upstreamBaseUrl = "upstream_base_url"
        case apiToken = "api_token"
        case authScheme = "auth_scheme"
    }
}

/// Response from `POST /credentials/oauth-provider` and
/// `POST /credentials/api-token`. The server returns the id of the
/// freshly-created `system.credential` item; pass this as
/// `credentialRef` on ``ConnectionInstallInput``.
public struct CreatedCredential: Codable, Sendable, Hashable {
    public let credentialId: String

    public init(credentialId: String) {
        self.credentialId = credentialId
    }

    enum CodingKeys: String, CodingKey {
        case credentialId = "credential_id"
    }
}
