import Foundation

/// The kind of a `system.credential` item.
///
/// Mirrors the server-side enum on `packages/types/core/system/credential.json`
/// (`kind: api_key | oauth_token | api_token`).
///
/// - `apiKey` — a Marfa-server-issued API key (returned to a caller for
///   future authenticated requests). Created by `client.keys.create(...)`.
/// - `oauthToken` — an OAuth provider config: authorize URL, token URL,
///   client_id, and encrypted client_secret. Created by
///   ``CredentialsNamespace/createOAuthProvider(_:)``. Shared across all
///   integrations that connect to the same upstream provider
///   (e.g. one `google.*` row used by both `google.calendar` and
///   `google.tasks`) via the `credential_ref` install parameter.
/// - `apiToken` — a static upstream bearer credential: `upstream_base_url`,
///   optional `auth_scheme` (``AuthScheme``), and encrypted token. Created
///   by ``CredentialsNamespace/createApiToken(_:)``. Used by token-based
///   integrations where the upstream has no OAuth surface — the proxy stamps
///   `Authorization: <scheme> <token>` on every outbound call.
///
/// Hand-written because the OpenAPI spec carries this as a plain string;
/// a closed Swift enum lets apps pattern-match without comparing raw
/// strings.
public enum CredentialKind: String, Codable, Sendable, Hashable, CaseIterable {
    case apiKey = "api_key"
    case oauthToken = "oauth_token"
    case apiToken = "api_token"
}
