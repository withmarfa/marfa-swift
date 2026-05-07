import Testing
import Foundation
@testable import MymeSDK

@Suite("PKCE primitives")
struct PKCETests {

    @Test("Verifier is RFC 7636 compliant — 43-128 chars, URL-safe base64")
    func verifierShape() {
        let verifier = PKCE.generateCodeVerifier()
        #expect(verifier.count >= 43)
        #expect(verifier.count <= 128)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    @Test("Verifier is unique across calls")
    func verifierUniqueness() {
        let a = PKCE.generateCodeVerifier()
        let b = PKCE.generateCodeVerifier()
        #expect(a != b)
    }

    @Test("S256 challenge is deterministic for a given verifier")
    func s256Deterministic() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        // Known SHA-256 of the verifier above per RFC 7636 §A.4 example.
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        #expect(PKCE.computeCodeChallenge(verifier: verifier) == expected)
    }

    @Test("State is unique and URL-safe")
    func stateShape() {
        let s = PKCE.generateState()
        #expect(s.count >= 16)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(s.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(PKCE.generateState() != s)
    }
}
