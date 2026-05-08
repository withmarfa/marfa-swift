import Testing
import Foundation
@testable import MymeSDK

/// Locks in `Token`'s decode behaviour against the RFC 6749 §5.1 wire
/// shape that `/auth/token` and `/auth/device/token` return.
///
/// Pre-fix, the auto-synthesised Codable looked for `scopes` (plural array)
/// and `expires_at` (ISO date) — neither field is on the wire — and threw
/// `DecodingError.keyNotFound("scopes")`, surfacing as
/// "data couldn't be read because it is missing" in user-facing flows
/// (OAuth code exchange, refresh, and device polling all hit it).
@Suite("Token wire decoding")
struct TokenWireDecodingTests {

    /// The exact JSON shape `/auth/token` returns for an OAuth code
    /// exchange with `openid profile email` granted, captured from
    /// staging during T-086 manual smoke.
    private let openIdResponse: String = """
    {
      "access_token": "myme_at_abc",
      "refresh_token": "myme_rt_def",
      "token_type": "bearer",
      "expires_in": 3600,
      "scope": "openid profile email",
      "id_token": "eyJhbGciOiJSUzI1NiJ9.payload.sig"
    }
    """

    @Test("decodes RFC 6749 wire shape from /auth/token")
    func decodesWireShape() throws {
        let data = openIdResponse.data(using: .utf8)!
        let token = try JSONDecoder().decode(Token.self, from: data)

        #expect(token.accessToken == "myme_at_abc")
        #expect(token.refreshToken == "myme_rt_def")
        #expect(token.tokenType == "bearer")
        #expect(token.idToken == "eyJhbGciOiJSUzI1NiJ9.payload.sig")
        #expect(token.scopes == ["openid", "profile", "email"])

        // expires_in 3600 → expiresAt ≈ now + 1h. Allow a generous window
        // for slow CI hardware between encode and assert.
        let now = Date()
        let expiry = try #require(token.expiresAt)
        let delta = expiry.timeIntervalSince(now)
        #expect(delta > 3500 && delta <= 3600)
    }

    @Test("decodes shape without id_token (non-OIDC grant)")
    func decodesWithoutIdToken() throws {
        let json = """
        {
          "access_token": "myme_at_xyz",
          "refresh_token": "myme_rt_xyz",
          "token_type": "bearer",
          "expires_in": 3600,
          "scope": "core.note:read"
        }
        """
        let token = try JSONDecoder().decode(Token.self, from: json.data(using: .utf8)!)
        #expect(token.idToken == nil)
        #expect(token.scopes == ["core.note:read"])
    }

    @Test("decodes shape without scope (server omitted) as empty array")
    func decodesEmptyScope() throws {
        let json = """
        {
          "access_token": "a",
          "token_type": "bearer",
          "expires_in": 3600
        }
        """
        let token = try JSONDecoder().decode(Token.self, from: json.data(using: .utf8)!)
        #expect(token.scopes == [])
        #expect(token.refreshToken == nil)
    }

    @Test("encode → decode round-trips through the persistence shape")
    func keychainRoundTrip() throws {
        let original = Token(
            accessToken: "myme_at_round",
            tokenType: "bearer",
            refreshToken: "myme_rt_round",
            idToken: "eyJ.payload.sig",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            scopes: ["openid", "profile"]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(Token.self, from: data)

        #expect(restored.accessToken == original.accessToken)
        #expect(restored.tokenType == original.tokenType)
        #expect(restored.refreshToken == original.refreshToken)
        #expect(restored.idToken == original.idToken)
        #expect(restored.scopes == original.scopes)
        #expect(restored.expiresAt == original.expiresAt)
    }

    @Test("decodes legacy persistence shape (`scopes` array, `expires_at`)")
    func decodesLegacyPersistedShape() throws {
        // A keychain blob written by an older SDK version that emitted
        // `scopes` (array) and `expires_at` (ISO date) instead of the new
        // canonical `scope` + `expires_at`. Backward compat: existing
        // installs don't lose their stored token on upgrade.
        let json = """
        {
          "access_token": "legacy_at",
          "token_type": "Bearer",
          "refresh_token": "legacy_rt",
          "scopes": ["core.note:read", "core.note:write"],
          "expires_at": "2030-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let token = try decoder.decode(Token.self, from: json.data(using: .utf8)!)
        #expect(token.accessToken == "legacy_at")
        #expect(token.scopes == ["core.note:read", "core.note:write"])
        #expect(token.expiresAt != nil)
    }

    @Test("decodes scope with multiple whitespace separators")
    func decodesScopeWithMultipleSpaces() throws {
        let json = """
        {
          "access_token": "a",
          "token_type": "bearer",
          "expires_in": 60,
          "scope": "openid  profile\\temail"
        }
        """
        let token = try JSONDecoder().decode(Token.self, from: json.data(using: .utf8)!)
        #expect(token.scopes == ["openid", "profile", "email"])
    }

    @Test("isExpired flips correctly")
    func isExpiredFlipsCorrectly() {
        let past = Token(accessToken: "a", expiresAt: Date(timeIntervalSinceNow: -10))
        let future = Token(accessToken: "b", expiresAt: Date(timeIntervalSinceNow: 3600))
        let neverExpires = Token(accessToken: "c")
        #expect(past.isExpired == true)
        #expect(future.isExpired == false)
        #expect(neverExpires.isExpired == false)
    }
}
