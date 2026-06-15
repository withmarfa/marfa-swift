import Testing
import Foundation
@testable import MarfaSDK

/// Locks in `Token`'s decode behavior against the RFC 6749 §5.1 wire
/// shape that `/auth/token` and `/auth/device/token` return.
///
/// Pre-fix, the auto-synthesized Codable looked for `scopes` (plural array)
/// and `expires_at` (ISO date) — neither field is on the wire — and threw
/// `DecodingError.keyNotFound("scopes")`, surfacing as
/// "data couldn't be read because it is missing" in user-facing flows
/// (OAuth code exchange, refresh, and device polling all hit it).
@Suite("Token wire decoding")
struct TokenWireDecodingTests {

    private let openIdResponse: String = """
    {
      "access_token": "marfa_at_abc",
      "refresh_token": "marfa_rt_def",
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

        #expect(token.accessToken == "marfa_at_abc")
        #expect(token.refreshToken == "marfa_rt_def")
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
          "access_token": "marfa_at_xyz",
          "refresh_token": "marfa_rt_xyz",
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
            accessToken: "marfa_at_round",
            tokenType: "bearer",
            refreshToken: "marfa_rt_round",
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
