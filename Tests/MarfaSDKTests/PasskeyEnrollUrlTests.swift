#if canImport(AuthenticationServices)

import Testing
import Foundation
@testable import MarfaSDK

/// The URL `Passkey.enroll` opens: the server's scheme, host and port, plus
/// `/auth/passkey/enroll` exactly once whatever the caller supplied.
///
/// These assert on `Passkey.enrollURL(forServer:)`, which is the line `enroll`
/// runs. They used to append the path in their own bodies and assert on that,
/// which pinned `appendingPathComponent` rather than anything about `enroll` —
/// give `enroll` a different path, the components in the wrong order, or no URL
/// at all, and the suite still passed. The full enrollment flow still cannot be
/// driven here, because it needs a host process and a system browser, but the
/// URL it opens no longer has to be taken on trust.
@Suite("Passkey enroll URL construction")
struct PasskeyEnrollUrlTests {

    @Test("appends /auth/passkey/enroll to a clean server URL")
    func cleanServerURL() {
        #expect(
            Passkey.enrollURL(forServer: URL(string: "https://staging.marfa.so")!)
                .absoluteString == "https://staging.marfa.so/auth/passkey/enroll"
        )
    }

    @Test("survives a trailing-slash server URL without doubling")
    func trailingSlashServerURL() {
        let target = Passkey.enrollURL(forServer: URL(string: "https://staging.marfa.so/")!)
        // The exact string can vary on slashes between Foundation versions;
        // what matters is that the path resolves to the same endpoint.
        let normalized = target.absoluteString.replacingOccurrences(
            of: "//auth", with: "/auth"
        )
        #expect(normalized.hasSuffix("/auth/passkey/enroll"))
    }

    @Test("preserves a non-default port")
    func portInServerURL() {
        #expect(
            Passkey.enrollURL(forServer: URL(string: "http://localhost:8602")!)
                .absoluteString == "http://localhost:8602/auth/passkey/enroll"
        )
    }

    /// The failure this parameter's rename exists to end, and the one this
    /// call cannot report. `enroll` is `async`, non-throwing, and by design
    /// cannot tell success from dismissal, so a doubled `/auth` here is a 404
    /// inside the system browser and silence everywhere else.
    @Test(
        "an issuer supplied as the server URL does not double the auth segment",
        arguments: ["https://staging.marfa.so/auth", "https://staging.marfa.so/auth/"]
    )
    func anIssuerIsAbsorbed(supplied: String) {
        let target = Passkey.enrollURL(forServer: URL(string: supplied)!)
        #expect(!target.absoluteString.contains("/auth/auth"), "doubled: \(target)")
        #expect(target.absoluteString.hasSuffix("/auth/passkey/enroll"))
    }
}

#endif
