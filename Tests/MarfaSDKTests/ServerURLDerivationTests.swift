#if canImport(AuthenticationServices) && !os(watchOS) && !os(tvOS)

import Testing
import Foundation
import AuthenticationServices
@testable import MarfaSDK
import MarfaSDKTestSupport

/// What moving the derivation inside the SDK must not change, and the one thing
/// it exists to fix.
///
/// Every test here is about a value that is computed rather than stored, so a
/// mistake in any of them is silent: nothing throws, an account simply is not
/// where the next read looks for it, and the user is asked to sign in again on
/// an app they were already signed into.
@Suite("Deriving the issuer from a server URL", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ServerURLDerivationTests {

    private let clientId = "client-abc"
    private let redirectURI = URL(string: "marfa-test://auth/callback")!
    private let scopes = ["core.note:read"]

    private static let token = #"{"access_token":"kept","expires_at":"2099-01-01T00:00:00Z","scope":"","token_type":"Bearer"}"#

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DerivationStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeAuth(serverURL: URL, storage: any SecureStorage) -> MarfaAuth {
        MarfaAuth(
            serverURL: serverURL,
            clientId: clientId,
            redirectURI: redirectURI,
            scopes: scopes,
            storage: storage,
            urlSession: stubbedSession()
        )
    }

    /// The acceptance criterion this change most needed, and the one whose
    /// failure would be worst.
    ///
    /// The account is written the way 14.2.0 wrote it — keyed on the issuer a
    /// correct consumer derived at its own call site — and read back through
    /// the new initializer, which derives internally. A round trip inside one
    /// build would pass whatever the key were; this passes only if the key did
    /// not move.
    @Test("a credential stored by 14.2.0 is still found after the derivation moves inside")
    func storedCredentialSurvivesTheChange() async throws {
        let serverURL = uniqueIssuer("derivation-continuity")
        let storage = InMemoryKeychain()

        // Exactly what `MarfaAuth(issuer: OAuthDiscovery.issuer(forServer:))`
        // produced in 14.2.0.
        let keyAsWrittenBefore = OAuthIssuer.storageKey(
            kind: "tokens",
            issuer: OAuthDiscovery.issuer(forServer: serverURL),
            clientId: clientId
        )
        try await storage.set(Self.token, for: keyAsWrittenBefore)

        let provider = try #require(
            await makeAuth(serverURL: serverURL, storage: storage).restore()
        )
        #expect(try await provider.currentToken().accessToken == "kept")
    }

    /// The failure that made this worth doing: a pre-11.4.0 host-only account
    /// stopped being promoted the moment consumers began passing a derived
    /// issuer, because the ambiguity check refuses a path and every Marfa
    /// issuer has one.
    ///
    /// Fails on the unfixed tree — `restore()` returns `nil` and the legacy
    /// value is left where it was, with nothing thrown.
    @Test("a pre-11.4.0 host-only account is promoted through an ordinary server URL")
    func legacyAccountIsMigrated() async throws {
        let serverURL = uniqueIssuer("derivation-legacy")
        let storage = InMemoryKeychain()

        // Host-only, which is all the old spelling ever carried.
        let legacyKey = OAuthIssuer.legacyTokenStorageKey(
            issuer: serverURL,
            clientId: clientId
        )
        let canonicalKey = OAuthIssuer.storageKey(
            kind: "tokens",
            issuer: OAuthDiscovery.issuer(forServer: serverURL),
            clientId: clientId
        )
        try await storage.set(Self.token, for: legacyKey)

        let provider = try #require(
            await makeAuth(serverURL: serverURL, storage: storage).restore()
        )

        #expect(try await provider.currentToken().accessToken == "kept")
        #expect(await storage.peek(account: canonicalKey) == Self.token)
        #expect(await storage.peek(account: legacyKey) == nil)
    }

    /// The guard the migration keeps, asked of the value it is actually about.
    ///
    /// A host-only account could have been written by a different authorization
    /// server on the same host, so a server that is not unambiguously ours does
    /// not claim one. Each shape is checked on its own rather than as a set,
    /// because a guard that refuses everything looks identical to a guard that
    /// works — which is exactly how the defect above survived.
    @Test(
        "an ambiguous server never claims a host-only account",
        arguments: ["/space", ":8443", "http"]
    )
    func ambiguousServerDoesNotMigrate(shape: String) async throws {
        let base = uniqueIssuer("derivation-ambiguous")
        let serverURL: URL = switch shape {
        case "/space": base.appending(path: "space")
        case ":8443": URL(string: "\(base.absoluteString):8443")!
        default: URL(string: base.absoluteString.replacingOccurrences(of: "https://", with: "http://"))!
        }

        let storage = InMemoryKeychain()
        let legacyKey = OAuthIssuer.legacyTokenStorageKey(
            issuer: serverURL,
            clientId: clientId
        )
        let canonicalKey = OAuthIssuer.storageKey(
            kind: "tokens",
            issuer: OAuthDiscovery.issuer(forServer: serverURL),
            clientId: clientId
        )
        try await storage.set(Self.token, for: legacyKey)

        #expect(try await makeAuth(serverURL: serverURL, storage: storage).restore() == nil)
        #expect(await storage.peek(account: canonicalKey) == nil)
        #expect(await storage.peek(account: legacyKey) == Self.token)
    }

    /// A caller handing the already-derived issuer to `serverURL:` — the value
    /// it was passing before this change — is not derived a second time.
    @Test("an already-derived issuer passed as the server URL is left alone")
    func anIssuerIsNotDerivedTwice() async throws {
        let serverURL = uniqueIssuer("derivation-guard")
        let issuer = OAuthDiscovery.issuer(forServer: serverURL)
        let storage = InMemoryKeychain()

        let auth = makeAuth(serverURL: issuer, storage: storage)
        #expect(auth.issuer == issuer, "double-derived to \(auth.issuer)")

        // And it addresses the same account, which is the half that matters:
        // the identity above could be right while the key still moved.
        try await storage.set(
            Self.token,
            for: OAuthIssuer.storageKey(kind: "tokens", issuer: issuer, clientId: clientId)
        )
        let provider = try #require(await auth.restore())
        #expect(try await provider.currentToken().accessToken == "kept")
    }

    /// The guard on the three entry points the test above does not reach.
    ///
    /// Pinning it on `MarfaAuth.init` alone left it unpinned on the *clear*
    /// path, which is the one its own rationale names as the reason it exists:
    /// a sign-in that double-derives fails loudly at discovery, and a clear
    /// that double-derives deletes nothing and reports success. Reverting any
    /// of these three to the unguarded `issuer(forServer:)` passed the whole
    /// suite before this.
    @Test("an issuer supplied as the server URL is absorbed on every entry point")
    func everyEntryPointAbsorbsAnIssuer() async throws {
        let serverURL = uniqueIssuer("derivation-guard-all")
        let issuer = OAuthDiscovery.issuer(forServer: serverURL)
        let accounts = [
            OAuthIssuer.storageKey(kind: "tokens", issuer: issuer, clientId: clientId),
            OAuthIssuer.storageKey(kind: "pending", issuer: issuer, clientId: clientId),
        ]

        // MarfaAuth.clearStoredCredentials — supplied the issuer, must still
        // address the accounts a sign-in wrote under it.
        let viaClear = InMemoryKeychain()
        for account in accounts { try await viaClear.set("live", for: account) }
        try await MarfaAuth.clearStoredCredentials(
            serverURL: issuer,
            clientId: clientId,
            storage: viaClear
        )
        for account in accounts {
            #expect(await viaClear.peek(account: account) == nil, "clearStoredCredentials left \(account)")
        }

        // MarfaSession.end — same, on the platforms MarfaAuth does not exist.
        let viaEnd = InMemoryKeychain()
        for account in accounts { try await viaEnd.set("live", for: account) }
        _ = try await MarfaSession.end(
            serverURL: issuer,
            clientId: clientId,
            storage: viaEnd
        )
        for account in accounts {
            #expect(await viaEnd.peek(account: account) == nil, "MarfaSession.end left \(account)")
        }

        // DeviceFlow.start — the handle keys its token account on this.
        let http = FakeDeviceFlowHTTPClient()
        try http.enqueueJSON(GuardDiscoveryDoc(serverURL: serverURL))
        http.enqueueDeviceCodeResponse()
        let handle = try await DeviceFlow.start(
            serverURL: issuer,
            clientId: clientId,
            scopes: scopes,
            storage: InMemoryKeychain(),
            httpClient: http,
            clock: ManualDeviceFlowClock()
        )
        #expect(handle.issuer == issuer, "DeviceFlow double-derived to \(handle.issuer)")
    }

    /// The path where getting this wrong says nothing at all: a clear that
    /// computes the wrong accounts deletes nothing and reports success, leaving
    /// a working credential on a device the person believes is signed out.
    @Test("clearing by server URL reaches every account a sign-in wrote")
    func clearingReachesTheAccountsSignInWrote() async throws {
        let serverURL = uniqueIssuer("derivation-clear")
        let issuer = OAuthDiscovery.issuer(forServer: serverURL)
        let storage = InMemoryKeychain()

        let accounts = [
            OAuthIssuer.storageKey(kind: "tokens", issuer: issuer, clientId: clientId),
            OAuthIssuer.storageKey(kind: "pending", issuer: issuer, clientId: clientId),
            OAuthIssuer.legacyStorageKey(kind: "tokens", issuer: issuer, clientId: clientId),
            OAuthIssuer.legacyStorageKey(kind: "pending", issuer: issuer, clientId: clientId),
        ]
        for account in accounts {
            try await storage.set("live", for: account)
        }

        try await MarfaAuth.clearStoredCredentials(
            serverURL: serverURL,
            clientId: clientId,
            storage: storage
        )

        for account in accounts {
            #expect(await storage.peek(account: account) == nil, "left behind: \(account)")
        }
    }
}

/// Well-known document for a deployment at `serverURL`, published under the
/// issuer derived from it.
private struct GuardDiscoveryDoc: Encodable {
    let issuer: String
    let authorization_endpoint: String
    let token_endpoint: String
    let revocation_endpoint: String
    let device_authorization_endpoint: String

    init(serverURL: URL) {
        let base = serverURL.absoluteString
        self.issuer = OAuthDiscovery.issuer(forServer: serverURL).absoluteString
        self.authorization_endpoint = "\(base)/auth/oauth2/authorize"
        self.token_endpoint = "\(base)/auth/oauth2/token"
        self.revocation_endpoint = "\(base)/auth/oauth2/revoke"
        self.device_authorization_endpoint = "\(base)/auth/device"
    }
}

/// Serves this suite's discovery documents without a queue, and so without a
/// shared one.
///
/// `MarfaAuthStubURLProtocol` holds its canned responses in a `static` array.
/// Suites run in parallel, so a second suite reaching for it consumes the
/// first's responses and both fail against an issuer neither asked about —
/// intermittently, since it depends which suite gets there first. This one is
/// stateless: it answers from the request it was handed.
///
/// The **origin** comes from the request, because every test here mints its
/// own. The **issuer path does not**: publishing `origin + <whatever path was
/// asked for>` would echo the request back, so RFC 8414 §3.3 could never fail
/// and a flow deriving `/auth/auth` would sail through. `/auth` flatly means a
/// wrong derivation is refused here exactly as a real server would refuse it.
private final class DerivationStubURLProtocol: URLProtocol, @unchecked Sendable {

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        components.path = ""
        let origin = components.url?.absoluteString ?? ""
        let body = """
        {
          "issuer": "\(origin)/auth",
          "authorization_endpoint": "\(origin)/auth/oauth2/authorize",
          "token_endpoint": "\(origin)/auth/oauth2/token",
          "revocation_endpoint": "\(origin)/auth/oauth2/revoke",
          "device_authorization_endpoint": "\(origin)/auth/device"
        }
        """
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

#endif
