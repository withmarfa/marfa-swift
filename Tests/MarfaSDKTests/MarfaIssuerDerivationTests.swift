import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// The OAuth issuer identifier of a Marfa server is not the server URL, and
/// every consumer of this SDK had assumed it was. These tests pin the
/// derivation and, more importantly, pin the failure the wrong value produces
/// so it can never again arrive as an opaque error code.
///
/// Each test mints its own host: `OAuthDiscovery.shared` is a process-wide
/// cache keyed by the canonical issuer, path included, and the suite runs in
/// parallel — see `uniqueServerURL(_:)`.
@Suite("Marfa issuer derivation", .timeLimit(.minutes(1)))
struct MarfaIssuerDerivationTests {

    /// A document as a Marfa deployment actually publishes it: the issuer
    /// carries `/auth`, and every endpoint hangs off that.
    private struct MarfaShapedDoc: Encodable {
        let issuer: String
        let authorization_endpoint: String
        let token_endpoint: String
        let revocation_endpoint: String
        let device_authorization_endpoint: String

        init(serverOrigin: URL) {
            let auth = "\(serverOrigin.absoluteString)/auth"
            self.issuer = auth
            self.authorization_endpoint = "\(auth)/oauth2/authorize"
            self.token_endpoint = "\(auth)/oauth2/token"
            self.revocation_endpoint = "\(auth)/oauth2/revoke"
            self.device_authorization_endpoint = "\(auth)/device"
        }
    }

    // MARK: - The derivation itself

    @Test("appends the auth path to a server URL")
    func appendsAuthPath() {
        let server = URL(string: "https://api.marfa.so")!
        #expect(
            OAuthDiscovery.issuer(forServer: server)
                == URL(string: "https://api.marfa.so/auth")
        )
    }

    @Test("a trailing slash does not double the separator")
    func trailingSlash() {
        let server = URL(string: "https://api.marfa.so/")!
        #expect(
            OAuthDiscovery.issuer(forServer: server).absoluteString
                == "https://api.marfa.so/auth"
        )
    }

    @Test("an explicit port survives the derivation")
    func explicitPortSurvives() {
        let server = URL(string: "http://127.0.0.1:8602")!
        #expect(
            OAuthDiscovery.issuer(forServer: server).absoluteString
                == "http://127.0.0.1:8602/auth"
        )
    }

    // MARK: - Discovery against a Marfa-shaped server

    /// The whole point. RFC 8414 §3 puts the well-known path *before* the
    /// issuer's own path, so a derived issuer resolves to the path-aware URL
    /// the platform serves, and the published issuer matches what was asked.
    @Test("the derived issuer resolves and verifies")
    func derivedIssuerResolves() async throws {
        let server = uniqueServerURL("marfa-issuer-ok")
        let http = FakeDeviceFlowHTTPClient()
        try http.enqueueJSON(MarfaShapedDoc(serverOrigin: server))

        let issuer = OAuthDiscovery.issuer(forServer: server)
        let endpoints = try await OAuthDiscovery.shared.endpoints(
            for: issuer,
            httpClient: http
        )

        #expect(endpoints.token == URL(string: "\(server.absoluteString)/auth/oauth2/token"))
        #expect(
            http.calls.first?.url
                == URL(string: "\(server.absoluteString)/.well-known/oauth-authorization-server/auth")
        )
    }

    /// The shipped defect, pinned. A bare server URL fetches the document
    /// successfully — the platform serves it at the root path too — and then
    /// fails the §3.3 identity check. Break `issuer(forServer:)` so it returns
    /// its argument unchanged and this is the test that fails.
    @Test("a bare server URL is refused as an issuer")
    func bareServerURLIsRefused() async throws {
        let server = uniqueServerURL("marfa-issuer-bare")
        let http = FakeDeviceFlowHTTPClient()
        try http.enqueueJSON(MarfaShapedDoc(serverOrigin: server))

        await #expect(throws: OAuthDiscoveryError.self) {
            _ = try await OAuthDiscovery.shared.endpoints(for: server, httpClient: http)
        }
    }

    /// A discovery failure has to say what is wrong in words. Without
    /// `LocalizedError` this read "The operation couldn't be completed.
    /// (MarfaSDK.OAuthDiscoveryError error 3.)", which is what a SwiftUI error
    /// row showed a person while sign-in was broken for four releases.
    @Test("an issuer mismatch describes itself")
    func mismatchIsReadable() async throws {
        let server = uniqueServerURL("marfa-issuer-readable")
        let http = FakeDeviceFlowHTTPClient()
        try http.enqueueJSON(MarfaShapedDoc(serverOrigin: server))

        do {
            _ = try await OAuthDiscovery.shared.endpoints(for: server, httpClient: http)
            Issue.record("expected the bare server URL to be refused")
        } catch let error as OAuthDiscoveryError {
            let message = error.localizedDescription
            #expect(message.contains("\(server.absoluteString)/auth"))
            #expect(message.contains("does not match the requested issuer"))
            #expect(!message.contains("couldn't be completed"))
        }
    }

    /// `OAuthIssuerValidationError` is internal but reaches consumers through
    /// `MarfaAuth.signIn` and `DeviceFlow.start`, so it needs the same
    /// treatment.
    @Test("a malformed issuer describes itself")
    func malformedIssuerIsReadable() {
        let error = OAuthIssuerValidationError.query("https://api.marfa.so?a=1")
        #expect(error.localizedDescription.contains("must not contain a query"))
        #expect(!error.localizedDescription.contains("couldn't be completed"))
    }
}
