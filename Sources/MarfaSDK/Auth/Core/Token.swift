import Foundation

/// An OAuth 2.0 access token bundle persisted by the SDK after a successful
/// auth flow.
///
/// ``Token`` is the unit of currency between auth flows (``MarfaAuth``,
/// ``DeviceFlow``, ``Passkey``) and the ``TokenProvider`` that the
/// ``MarfaClient`` transport reaches for on every request. Tokens are
/// short-lived; ``StoredTokenProvider`` refreshes them transparently when
/// ``isExpired`` flips to `true`.
///
/// Wire shape conforms to RFC 6749 §5.1: `access_token`, `token_type`,
/// `refresh_token`, `expires_in` (seconds), `scope` (single space-separated
/// string), and — when `openid` was granted — `id_token` (a signed JWT).
/// The decoder normalises `expires_in` to an absolute `expiresAt` date and
/// splits `scope` into a `[String]` for ergonomic Swift consumption.
///
/// The encode side emits a canonical persistence shape (`scope` string,
/// `expires_at` ISO 8601) so a Token round-trips through Keychain
/// storage without losing state. The decoder accepts both wire forms
/// (`expires_in` + `scope` from the server) and persistence forms
/// (`expires_at` + `scope` from Keychain).
public struct Token: Codable, Sendable, Hashable {
    /// The bearer string sent in the `Authorization` header.
    public let accessToken: String

    /// Token type, e.g. `"bearer"`. Servers must echo this verbatim per
    /// RFC 6749 §5.1.
    public let tokenType: String

    /// Refresh token, if the server issued one. Used by
    /// ``StoredTokenProvider`` to re-mint an expired access token without
    /// re-running the user-facing flow.
    public let refreshToken: String?

    /// OIDC ID Token (JWT) when `openid` was in the granted scopes.
    /// Optional — non-OIDC flows omit it. Consumers who need to verify
    /// the JWT against the platform JWKS can fetch
    /// `/.well-known/jwks.json` from the issuer.
    public let idToken: String?

    /// Absolute expiry of the access token. Computed at decode time from
    /// the wire `expires_in` field; persisted as an ISO 8601 date. Nil
    /// when the server omitted both fields.
    public let expiresAt: Date?

    /// Granted scopes. The wire spec carries them as a single
    /// space-separated string in the `scope` field; the SDK splits to
    /// `[String]` for ergonomic consumption. Empty when the server
    /// omitted `scope`.
    public let scopes: [String]

    /// True when ``expiresAt`` is in the past. ``StoredTokenProvider``
    /// gates its refresh logic on this property.
    public var isExpired: Bool {
        guard let expiry = expiresAt else { return false }
        return expiry <= Date()
    }

    public init(
        accessToken: String,
        tokenType: String = "bearer",
        refreshToken: String? = nil,
        idToken: String? = nil,
        expiresAt: Date? = nil,
        scopes: [String] = []
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresAt = "expires_at"
        case expiresIn = "expires_in"
        case scope
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.accessToken = try c.decode(String.self, forKey: .accessToken)
        self.tokenType = try c.decode(String.self, forKey: .tokenType)
        self.refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        self.idToken = try c.decodeIfPresent(String.self, forKey: .idToken)

        // Wire form (`expires_in` seconds) wins when present — the server
        // sends it on every fresh grant. Falls back to `expires_at` (the
        // canonical persistence form). Both absent → no expiry tracked.
        if let expiresInSeconds = try c.decodeIfPresent(Int.self, forKey: .expiresIn) {
            self.expiresAt = Date().addingTimeInterval(TimeInterval(expiresInSeconds))
        } else if let absolute = try c.decodeIfPresent(Date.self, forKey: .expiresAt) {
            self.expiresAt = absolute
        } else {
            self.expiresAt = nil
        }

        // Both wire and persistence forms carry `scope` as a single
        // space-separated string per RFC 6749 §3.3.
        if let scopeStr = try c.decodeIfPresent(String.self, forKey: .scope) {
            self.scopes = scopeStr
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
        } else {
            self.scopes = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accessToken, forKey: .accessToken)
        try c.encode(tokenType, forKey: .tokenType)
        try c.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try c.encodeIfPresent(idToken, forKey: .idToken)
        // Persistence canon: `expires_at` (ISO 8601 absolute date) and
        // `scope` (single space-separated string). The decoder above
        // reads both wire and persistence forms.
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encode(scopes.joined(separator: " "), forKey: .scope)
    }
}
