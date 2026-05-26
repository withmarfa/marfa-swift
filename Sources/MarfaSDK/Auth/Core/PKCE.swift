import CryptoKit
import Foundation

/// PKCE (Proof Key for Code Exchange) primitives per RFC 7636.
///
/// Used by ``MarfaAuth`` to bind the authorization request to the token
/// exchange — the verifier never leaves the client, and the server checks
/// the SHA-256 challenge against the original verifier on token redemption.
public enum PKCE {
    /// Generates a cryptographically-random code verifier per RFC 7636 §4.1.
    ///
    /// 32 random bytes encoded as URL-safe base64 without padding yields a
    /// 43-character verifier — within the spec's 43-128 range and high
    /// enough entropy that brute-forcing is computationally infeasible.
    public static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(result == errSecSuccess, "SecRandomCopyBytes failed: \(result)")
        return base64URLEncode(Data(bytes))
    }

    /// Computes the S256 code challenge for `verifier` per RFC 7636 §4.2.
    ///
    /// The result is the URL-safe-base64-without-padding encoding of
    /// SHA-256(`verifier`). Servers compare this challenge against the
    /// stored value on token redemption.
    public static func computeCodeChallenge(verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(hash))
    }

    /// Generates an opaque random `state` parameter for the authorization
    /// request, per OAuth 2.0 §10.12.
    ///
    /// Used to bind the redirect callback to the originating request,
    /// defeating CSRF on the redirect endpoint.
    public static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(result == errSecSuccess, "SecRandomCopyBytes failed: \(result)")
        return base64URLEncode(Data(bytes))
    }

    /// URL-safe base64 encoding without padding per RFC 4648 §5.
    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
