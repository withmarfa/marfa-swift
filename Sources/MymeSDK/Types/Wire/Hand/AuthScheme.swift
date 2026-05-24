import Foundation

/// Authorization scheme stamped by the Myme proxy on outbound calls
/// when the connection's credential is of kind `api_token`.
///
/// Mirrors the server's `auth_scheme` enum (T-246) on
/// `system.credential.api_token_config`. Some upstreams (Readwise,
/// HubSpot, Atlassian) reject the default `Bearer` scheme and require
/// `Token` or `Basic`; this enum carries the choice from the credential
/// row through the proxy.
///
/// Hand-written because the OpenAPI spec carries this as a plain string;
/// a closed Swift enum lets apps pattern-match without comparing raw
/// strings.
public enum AuthScheme: String, Codable, Sendable, Hashable, CaseIterable {
    /// `Authorization: Bearer <token>`. Default for most upstreams.
    case bearer = "Bearer"

    /// `Authorization: Token <token>`. Used by Readwise, GitHub PATs.
    case token = "Token"

    /// `Authorization: Basic <token>`. The token is expected to be
    /// pre-encoded base64 of the credential pair (or the upstream's
    /// equivalent — the proxy does not encode for the caller).
    case basic = "Basic"
}
