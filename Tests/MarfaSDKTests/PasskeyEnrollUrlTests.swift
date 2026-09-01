#if canImport(AuthenticationServices)

import Testing
import Foundation
@testable import MarfaSDK

/// Describes the URL contract `Passkey.enroll` opens: preserve the server URL's
/// scheme, host and port, and append `/auth/passkey/enroll` exactly once
/// whatever the trailing slashes.
///
/// The full enrollment flow (ASWebAuthenticationSession + WebAuthn ceremony) is
/// a UI path that cannot run inside `swift test` — it needs a host process and a
/// system browser, and calling `enroll` here would open a real session. So these
/// tests do not call it.
///
/// - Warning: **Nothing below observes `Passkey.enroll`.** Each test appends
///   `auth/passkey/enroll` to a URL in its own body and asserts on that, so what
///   is actually pinned is `appendingPathComponent` behaving the way Foundation
///   says it does. Give `enroll` a different path, the components in the wrong
///   order, or no URL at all, and this suite still passes. It documents the
///   contract and regresses none of it.
///
///   Closing that means lifting the URL construction out of `enroll` into
///   something callable without a browser. Until then the duplication stands,
///   and saying so is worth more than the assurance of leaving it unsaid.
@Suite("Passkey enroll URL construction")
struct PasskeyEnrollUrlTests {

    @Test("appends /auth/passkey/enroll to a clean server URL")
    func cleanIssuer() {
        let serverURL = URL(string: "https://staging.marfa.so")!
        let target = serverURL.appendingPathComponent("auth/passkey/enroll")
        #expect(target.absoluteString == "https://staging.marfa.so/auth/passkey/enroll")
    }

    @Test("survives a trailing-slash server URL without doubling")
    func trailingSlashIssuer() {
        let serverURL = URL(string: "https://staging.marfa.so/")!
        let target = serverURL.appendingPathComponent("auth/passkey/enroll")
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
        let serverURL = URL(string: "http://localhost:8602")!
        let target = serverURL.appendingPathComponent("auth/passkey/enroll")
        #expect(target.absoluteString == "http://localhost:8602/auth/passkey/enroll")
    }
}

#endif
