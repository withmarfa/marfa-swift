import Foundation

/// An OAuth 2.0 access token bundle persisted by the SDK after a successful
/// auth flow.
///
/// ``Token`` is the unit of currency between auth flows (``MymeAuth``,
/// ``DeviceFlow``, ``Passkey``) and the ``TokenProvider`` that the
/// ``MymeClient`` transport reaches for on every request. Tokens are
/// short-lived; ``StoredTokenProvider`` refreshes them transparently when
/// ``isExpired`` flips to `true`.
///
/// Wire field names are snake_case (`access_token`, `refresh_token`,
/// `expires_at`); the Swift surface uses camelCase via the Codable
/// `CodingKeys` mapping below.
public struct Token: Codable, Sendable, Hashable {
    /// The bearer string sent in the `Authorization` header.
    public let accessToken: String

    /// Token type, e.g. `"Bearer"`. Servers must echo this verbatim per
    /// RFC 6749 §5.1; preserved on the wire for round-trip fidelity.
    public let tokenType: String

    /// Refresh token, if the server issued one. Used by
    /// ``StoredTokenProvider`` to re-mint an expired access token without
    /// re-running the user-facing flow.
    public let refreshToken: String?

    /// Absolute expiry of the access token. The wire spec allows either
    /// `expires_in` (seconds) or `expires_at` (ISO 8601 timestamp); the SDK
    /// normalises to an absolute date at parse time so the renewal logic
    /// doesn't need to track when the token was issued.
    public let expiresAt: Date?

    /// Granted scopes, space-separated when serialised to the wire per
    /// RFC 6749 §3.3, returned as an array here for convenience.
    public let scopes: [String]

    /// True when ``expiresAt`` is in the past. ``StoredTokenProvider``
    /// gates its refresh logic on this property.
    public var isExpired: Bool {
        guard let expiry = expiresAt else { return false }
        return expiry <= Date()
    }

    public init(
        accessToken: String,
        tokenType: String = "Bearer",
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        scopes: [String] = []
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case scopes
    }
}
