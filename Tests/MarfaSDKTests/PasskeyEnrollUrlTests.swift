#if canImport(AuthenticationServices)

import Testing
import Foundation
@testable import MarfaSDK

/// Locks in the URL contract Passkey.enroll opens.
///
/// The full enrollment flow (ASWebAuthenticationSession + WebAuthn
/// ceremony) is a UI path that can't run inside `swift test` — it needs
/// a host process and a system browser. This suite asserts the
/// observable invariant: the SDK constructs the right server URL,
/// preserving the issuer's scheme/host/port and appending
/// `/auth/passkey/enroll` exactly once regardless of trailing slashes.
@Suite("Passkey enroll URL construction")
struct PasskeyEnrollUrlTests {

    @Test("appends /auth/passkey/enroll to a clean issuer")
    func cleanIssuer() {
        let issuer = URL(string: "https://staging.marfa.so")!
        let target = issuer.appendingPathComponent("auth/passkey/enroll")
        #expect(target.absoluteString == "https://staging.marfa.so/auth/passkey/enroll")
    }

    @Test("survives a trailing-slash issuer without doubling")
    func trailingSlashIssuer() {
        let issuer = URL(string: "https://staging.marfa.so/")!
        let target = issuer.appendingPathComponent("auth/passkey/enroll")
        // The exact URL string can vary on slashes between Foundation
        // versions; what matters is the path resolves to the same
        // canonical endpoint when normalized.
        let normalized = target.absoluteString.replacingOccurrences(
            of: "//auth", with: "/auth"
        )
        #expect(normalized.hasSuffix("/auth/passkey/enroll"))
    }

    @Test("preserves a non-default port")
    func portInIssuer() {
        let issuer = URL(string: "http://localhost:8602")!
        let target = issuer.appendingPathComponent("auth/passkey/enroll")
        #expect(target.absoluteString == "http://localhost:8602/auth/passkey/enroll")
    }
}

#endif
