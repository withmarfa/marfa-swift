#if canImport(AuthenticationServices) && !os(watchOS) && !os(tvOS)

import Testing
import Foundation
import AuthenticationServices
@testable import MarfaSDK
import MarfaSDKTestSupport

/// URLProtocol stub for stubbing the token + revoke HTTP layer underneath
/// `URLSession`. Mirrors the shape of `StubURLProtocol` in
/// `TransportRetryTests.swift`; lives in its own type because Swift
/// requires URLProtocol subclasses at file scope and the transport
/// version is fileprivate to that suite.
final class MarfaAuthStubURLProtocol: URLProtocol, @unchecked Sendable {

    struct Canned {
        var statusCode: Int
        var headers: [String: String]
        var body: Data
        var error: URLError?
    }

    nonisolated(unsafe) static var canned: [Canned] = []
    nonisolated(unsafe) static var recorded: [(URLRequest, Data?)] = []
    private static let lock = NSLock()

    static func reset(with responses: [Canned]) {
        lock.lock(); defer { lock.unlock() }
        canned = responses
        recorded = []
    }

    static func recordedRequests() -> [(URLRequest, Data?)] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        // URLProtocol bodyStream nuance: when URLSession delivers a body
        // via bodyStream we must drain it manually, otherwise `httpBody`
        // is nil even though the form body is wire-sent.
        var bodyData: Data? = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: 4096)
                if read <= 0 { break }
                collected.append(buf, count: read)
            }
            stream.close()
            bodyData = collected
        }
        Self.recorded.append((request, bodyData))
        if Self.canned.isEmpty {
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let next = Self.canned.removeFirst()
        Self.lock.unlock()

        if let error = next.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: next.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// URLSession routed through the stub.
private func makeStubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MarfaAuthStubURLProtocol.self]
    return URLSession(configuration: config)
}

/// Stub well-known discovery doc — the SDK reads this on first OAuth
/// operation. Tests queue it ahead of their scripted token/revoke
/// responses.
private func discoveryCanned(for issuer: URL) -> MarfaAuthStubURLProtocol.Canned {
    let base = issuer.absoluteString
    let body = """
    {
      "issuer": "\(base)",
      "authorization_endpoint": "\(base)/auth/oauth2/authorize",
      "token_endpoint": "\(base)/auth/oauth2/token",
      "revocation_endpoint": "\(base)/auth/oauth2/revoke",
      "device_authorization_endpoint": "\(base)/auth/device"
    }
    """
    return .init(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(body.utf8),
        error: nil
    )
}

private actor MigrationTrackingStorage: SecureStorage {
    private var values: [String: String]
    private var setCounts: [String: Int] = [:]
    private var deleteCounts: [String: Int] = [:]

    init(values: [String: String]) {
        self.values = values
    }

    func set(_ value: String, for account: String) async throws {
        await Task.yield()
        values[account] = value
        setCounts[account, default: 0] += 1
    }

    func get(for account: String) async throws -> String? {
        await Task.yield()
        return values[account]
    }

    func delete(for account: String) async throws {
        await Task.yield()
        values.removeValue(forKey: account)
        deleteCounts[account, default: 0] += 1
    }

    func value(for account: String) -> String? {
        values[account]
    }

    func setCount(for account: String) -> Int {
        setCounts[account, default: 0]
    }

    func deleteCount(for account: String) -> Int {
        deleteCounts[account, default: 0]
    }
}

@Suite("MarfaAuth sign-in flow", .serialized)
@MainActor
struct MarfaAuthSignInTests {

    /// `restore()` runs OAuth discovery, whose cache is process-wide and
    /// keyed by origin. A struct suite is instantiated once per test, so
    /// each test gets an origin nobody else uses and starts cold — which
    /// is what keeps the scripted response queue aligned without clearing
    /// the shared cache out from under other suites.
    let issuer = uniqueIssuer("marfa-auth-signin")
    let clientId = "test-client"
    let redirectURI = URL(string: "marfa-test://auth/callback")!
    let scopes = ["openid", "profile", "email"]

    func makeAuth(session: URLSession, storage: InMemoryKeychain = InMemoryKeychain()) -> MarfaAuth {
        MarfaAuth(
            issuer: issuer,
            clientId: clientId,
            redirectURI: redirectURI,
            scopes: scopes,
            storage: storage,
            urlSession: session
        )
    }

    // MARK: - buildAuthorizeURL

    @Test("buildAuthorizeURL includes every required OAuth + PKCE query parameter")
    func authorizeURLParameters() throws {
        let auth = makeAuth(session: makeStubbedSession())
        let url = try auth.buildAuthorizeURL(
            authorize: URL(string: "https://auth-sign-in.example.test/auth/oauth2/authorize")!,
            challenge: "challenge-abc",
            state: "state-xyz"
        )

        #expect(url.scheme == "https")
        #expect(url.host == "auth-sign-in.example.test")
        #expect(url.path == "/auth/oauth2/authorize")

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let params = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(params["response_type"] == "code")
        #expect(params["client_id"] == clientId)
        #expect(params["redirect_uri"] == redirectURI.absoluteString)
        #expect(params["scope"] == "openid profile email")
        #expect(params["code_challenge"] == "challenge-abc")
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["state"] == "state-xyz")
    }

    @Test("buildAuthorizeURL URL-encodes redirect URI and state safely")
    func authorizeURLEncoding() throws {
        let auth = MarfaAuth(
            issuer: issuer,
            clientId: "client with spaces",
            redirectURI: URL(string: "marfa-test://path?with=query&special=%26")!,
            scopes: ["scope+1", "scope+2"],
            storage: InMemoryKeychain(),
            urlSession: makeStubbedSession()
        )
        let url = try auth.buildAuthorizeURL(
            authorize: URL(string: "https://auth-sign-in.example.test/auth/oauth2/authorize")!,
            challenge: "c",
            state: "s"
        )

        // URLComponents handles percent-encoding internally; consumer
        // can round-trip the redirect URI back to the original.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let redirect = components.queryItems!.first { $0.name == "redirect_uri" }!.value!
        #expect(redirect == "marfa-test://path?with=query&special=%26")
    }

    // MARK: - parseCallback

    @Test("parseCallback returns code and state on happy path")
    func parseCallbackHappy() throws {
        let auth = makeAuth(session: makeStubbedSession())
        let callback = URL(string: "marfa-test://auth/callback?code=auth-code-123&state=state-xyz")!

        let (code, state) = try auth.parseCallback(callback)

        #expect(code == "auth-code-123")
        #expect(state == "state-xyz")
    }

    @Test("parseCallback raises OAuthError from ?error= query")
    func parseCallbackError() throws {
        let auth = makeAuth(session: makeStubbedSession())
        let callback = URL(string: "marfa-test://auth/callback?error=invalid_grant&error_description=expired+code")!

        do {
            _ = try auth.parseCallback(callback)
            Issue.record("expected OAuthError")
        } catch let error as OAuthError {
            #expect(error.oauthCode == .invalidGrant)
            #expect(error.code == "invalid_grant")
            #expect(error.message.contains("expired"))
        }
    }

    @Test("parseCallback preserves non-standard error code as .unknown")
    func parseCallbackUnknownError() throws {
        let auth = makeAuth(session: makeStubbedSession())
        let callback = URL(string: "marfa-test://auth/callback?error=access_denied&error_description=user+declined")!

        do {
            _ = try auth.parseCallback(callback)
            Issue.record("expected OAuthError")
        } catch let error as OAuthError {
            #expect(error.oauthCode == .unknown)
            // The raw wire code is preserved on MarfaError.code even when
            // the typed enum maps it to .unknown.
            #expect(error.code == "access_denied")
        }
    }

    @Test("parseCallback throws invalid_callback when code missing")
    func parseCallbackMissingCode() throws {
        let auth = makeAuth(session: makeStubbedSession())
        let callback = URL(string: "marfa-test://auth/callback?state=only")!

        do {
            _ = try auth.parseCallback(callback)
            Issue.record("expected OAuthError")
        } catch let error as OAuthError {
            #expect(error.code == "invalid_callback")
        }
    }

    // MARK: - exchangeCode

    @Test("exchangeCode POSTs form-encoded body to the discovered token endpoint and decodes Token")
    func exchangeCodeHappy() async throws {
        let session = makeStubbedSession()
        let auth = makeAuth(session: session)
        let body = #"""
        {
          "access_token": "marfa_at_aaa",
          "refresh_token": "marfa_rt_bbb",
          "token_type": "Bearer",
          "expires_in": 3600,
          "scope": "openid profile email"
        }
        """#
        MarfaAuthStubURLProtocol.reset(with: [
            .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8), error: nil)
        ])

        let token = try await auth.exchangeCode(
            code: "auth-code-123",
            verifier: "verifier-xyz",
            tokenEndpoint: URL(string: "https://auth-sign-in.example.test/auth/oauth2/token")!
        )

        #expect(token.accessToken == "marfa_at_aaa")
        #expect(token.refreshToken == "marfa_rt_bbb")
        #expect(token.tokenType == "Bearer")
        #expect(token.scopes == ["openid", "profile", "email"])

        let recorded = MarfaAuthStubURLProtocol.recordedRequests()
        #expect(recorded.count == 1)
        let (req, requestBody) = recorded[0]
        #expect(req.url?.path == "/auth/oauth2/token")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let form = String(data: requestBody ?? Data(), encoding: .utf8)!
        #expect(form.contains("grant_type=authorization_code"))
        #expect(form.contains("code=auth-code-123"))
        #expect(form.contains("code_verifier=verifier-xyz"))
        #expect(form.contains("client_id=test-client"))
    }

    @Test("exchangeCode surfaces OAuthError on a 400 invalid_grant body")
    func exchangeCodeInvalidGrant() async throws {
        let session = makeStubbedSession()
        let auth = makeAuth(session: session)
        let body = #"""
        {
          "error": "invalid_grant",
          "error_description": "code expired"
        }
        """#
        MarfaAuthStubURLProtocol.reset(with: [
            .init(statusCode: 400, headers: ["Content-Type": "application/json"], body: Data(body.utf8), error: nil)
        ])

        do {
            _ = try await auth.exchangeCode(
                code: "c",
                verifier: "v",
                tokenEndpoint: URL(string: "https://auth-sign-in.example.test/auth/oauth2/token")!
            )
            Issue.record("expected OAuthError(invalid_grant)")
        } catch let error as OAuthError {
            #expect(error.oauthCode == .invalidGrant)
            #expect(error.status == 400)
        }
    }

    // MARK: - restore

    @Test("restore returns nil when storage is empty")
    func restoreEmpty() async throws {
        let auth = makeAuth(session: makeStubbedSession(), storage: InMemoryKeychain())
        let provider = try await auth.restore()
        #expect(provider == nil)
    }

    @Test("restore returns a StoredTokenProvider when a token is on disk")
    func restoreHasToken() async throws {
        let storage = InMemoryKeychain()
        let key = OAuthIssuer.storageKey(
            kind: "tokens",
            issuer: issuer,
            clientId: clientId
        )
        let json = #"{"access_token":"a","expires_at":"2099-01-01T00:00:00Z","scope":"","token_type":"Bearer"}"#
        try await storage.set(json, for: key)

        // restore() runs OAuth discovery to resolve the refresh endpoint.
        MarfaAuthStubURLProtocol.reset(with: [discoveryCanned(for: issuer)])

        let auth = makeAuth(session: makeStubbedSession(), storage: storage)
        let provider = try await auth.restore()

        #expect(provider != nil)
        let token = try await provider!.currentToken()
        #expect(token.accessToken == "a")
    }

    @Test("issuer identity isolates PKCE state and restored tokens")
    func issuerIdentityIsolatesPendingAndTokens() async throws {
        let storage = InMemoryKeychain()
        let issuerA = URL(string: "https://tenant-auth.example.test:8443/tenant-a")!
        let issuerB = URL(string: "http://tenant-auth.example.test:9443/tenant-b")!
        let authA = MarfaAuth(
            issuer: issuerA,
            clientId: clientId,
            redirectURI: redirectURI,
            scopes: scopes,
            storage: storage,
            urlSession: makeStubbedSession()
        )
        let authB = MarfaAuth(
            issuer: issuerB,
            clientId: clientId,
            redirectURI: redirectURI,
            scopes: scopes,
            storage: storage,
            urlSession: makeStubbedSession()
        )

        try await authA.persistPendingForTesting(verifier: "verifier-a", state: "state-a")
        try await authB.persistPendingForTesting(verifier: "verifier-b", state: "state-b")
        let pendingKeyA = OAuthIssuer.storageKey(kind: "pending", issuer: issuerA, clientId: clientId)
        let pendingKeyB = OAuthIssuer.storageKey(kind: "pending", issuer: issuerB, clientId: clientId)
        #expect(await storage.peek(account: pendingKeyA)?.contains("verifier-a") == true)
        #expect(await storage.peek(account: pendingKeyB)?.contains("verifier-b") == true)

        let tokenA = #"{"access_token":"token-a","expires_at":"2099-01-01T00:00:00Z","scope":"","token_type":"Bearer"}"#
        let tokenB = #"{"access_token":"token-b","expires_at":"2099-01-01T00:00:00Z","scope":"","token_type":"Bearer"}"#
        let tokenKeyA = OAuthIssuer.storageKey(kind: "tokens", issuer: issuerA, clientId: clientId)
        let tokenKeyB = OAuthIssuer.storageKey(kind: "tokens", issuer: issuerB, clientId: clientId)
        try await storage.set(tokenA, for: tokenKeyA)
        try await storage.set(tokenB, for: tokenKeyB)
        await OAuthDiscovery.shared.reset(for: issuerA)
        await OAuthDiscovery.shared.reset(for: issuerB)
        MarfaAuthStubURLProtocol.reset(with: [
            discoveryCanned(for: issuerA),
            discoveryCanned(for: issuerB),
        ])

        let providerA = try #require(await authA.restore())
        let providerB = try #require(await authB.restore())
        #expect(try await providerA.currentToken().accessToken == "token-a")
        #expect(try await providerB.currentToken().accessToken == "token-b")
    }

    @Test("restore migrates an origin-only token only for an HTTPS root issuer")
    func restoreMigratesLegacyTokenKey() async throws {
        let storage = InMemoryKeychain()
        let rootIssuer = URL(string: "https://legacy-auth.example.test")!
        let legacyKey = OAuthIssuer.legacyTokenStorageKey(issuer: rootIssuer, clientId: clientId)
        let canonicalKey = OAuthIssuer.storageKey(kind: "tokens", issuer: rootIssuer, clientId: clientId)
        let token = #"{"access_token":"legacy-token","expires_at":"2099-01-01T00:00:00Z","scope":"","token_type":"Bearer"}"#
        try await storage.set(token, for: legacyKey)
        await OAuthDiscovery.shared.reset(for: rootIssuer)
        MarfaAuthStubURLProtocol.reset(with: [discoveryCanned(for: rootIssuer)])
        let auth = MarfaAuth(
            issuer: rootIssuer,
            clientId: clientId,
            redirectURI: redirectURI,
            scopes: scopes,
            storage: storage,
            urlSession: makeStubbedSession()
        )

        let provider = try #require(await auth.restore())
        #expect(try await provider.currentToken().accessToken == "legacy-token")
        #expect(await storage.peek(account: canonicalKey) == token)
        #expect(await storage.peek(account: legacyKey) == nil)
    }

    @Test("restore never promotes a host-only token into an ambiguous issuer")
    func restoreDoesNotMigrateAmbiguousIssuer() async throws {
        let cases = [
            URL(string: "https://ambiguous-auth.example.test/tenant")!,
            URL(string: "https://ambiguous-auth.example.test:8443")!,
            URL(string: "http://ambiguous-auth.example.test")!,
        ]

        for (index, ambiguousIssuer) in cases.enumerated() {
            let storage = InMemoryKeychain()
            let caseClient = "client-\(index)"
            let legacyKey = OAuthIssuer.legacyTokenStorageKey(
                issuer: ambiguousIssuer,
                clientId: caseClient
            )
            let canonicalKey = OAuthIssuer.storageKey(
                kind: "tokens",
                issuer: ambiguousIssuer,
                clientId: caseClient
            )
            try await storage.set("legacy-token", for: legacyKey)
            let auth = MarfaAuth(
                issuer: ambiguousIssuer,
                clientId: caseClient,
                redirectURI: redirectURI,
                scopes: scopes,
                storage: storage,
                urlSession: makeStubbedSession()
            )

            #expect(try await auth.restore() == nil)
            #expect(await storage.peek(account: canonicalKey) == nil)
            #expect(await storage.peek(account: legacyKey) == "legacy-token")
        }
    }

    @Test("concurrent restores promote a legacy root token once")
    func concurrentRestoreMigratesOnce() async throws {
        let rootIssuer = URL(string: "https://concurrent-migration.example.test")!
        let legacyKey = OAuthIssuer.legacyTokenStorageKey(issuer: rootIssuer, clientId: clientId)
        let canonicalKey = OAuthIssuer.storageKey(kind: "tokens", issuer: rootIssuer, clientId: clientId)
        let token = #"{"access_token":"legacy-token","expires_at":"2099-01-01T00:00:00Z","scope":"","token_type":"Bearer"}"#
        let storage = MigrationTrackingStorage(values: [legacyKey: token])
        let session = makeStubbedSession()
        let firstAuth = MarfaAuth(
            issuer: rootIssuer,
            clientId: clientId,
            redirectURI: redirectURI,
            scopes: scopes,
            storage: storage,
            urlSession: session
        )
        let secondAuth = MarfaAuth(
            issuer: rootIssuer,
            clientId: clientId,
            redirectURI: redirectURI,
            scopes: scopes,
            storage: storage,
            urlSession: session
        )
        await OAuthDiscovery.shared.reset(for: rootIssuer)
        MarfaAuthStubURLProtocol.reset(with: [discoveryCanned(for: rootIssuer)])

        async let firstProvider = firstAuth.restore()
        async let secondProvider = secondAuth.restore()
        let providers = try await (firstProvider, secondProvider)

        #expect(try await providers.0?.currentToken().accessToken == "legacy-token")
        #expect(try await providers.1?.currentToken().accessToken == "legacy-token")
        #expect(await storage.value(for: canonicalKey) == token)
        #expect(await storage.value(for: legacyKey) == nil)
        #expect(await storage.setCount(for: canonicalKey) == 1)
        #expect(await storage.deleteCount(for: legacyKey) == 1)
    }

    @Test("length-prefixed storage accounts separate delimiter collisions")
    func storageKeyEncodingIsUnambiguous() {
        let issuerA = URL(string: "https://collision.example.test/a:b")!
        let issuerB = URL(string: "https://collision.example.test/a")!
        let keyA = OAuthIssuer.storageKey(kind: "tokens", issuer: issuerA, clientId: "c")
        let keyB = OAuthIssuer.storageKey(kind: "tokens", issuer: issuerB, clientId: "b:c")

        #expect(
            "\(OAuthIssuer.identity(for: issuerA)):c"
                == "\(OAuthIssuer.identity(for: issuerB)):b:c"
        )
        #expect(keyA != keyB)
    }

    @Test("restore keeps a canonical token when a legacy key also exists")
    func restorePrefersCanonicalTokenKey() async throws {
        let storage = InMemoryKeychain()
        let rootIssuer = URL(string: "https://canonical-auth.example.test")!
        let legacyKey = OAuthIssuer.legacyTokenStorageKey(issuer: rootIssuer, clientId: clientId)
        let canonicalKey = OAuthIssuer.storageKey(kind: "tokens", issuer: rootIssuer, clientId: clientId)
        let legacyToken = #"{"access_token":"legacy","expires_at":"2099-01-01T00:00:00Z","scope":"","token_type":"Bearer"}"#
        let canonicalToken = #"{"access_token":"canonical","expires_at":"2099-01-01T00:00:00Z","scope":"","token_type":"Bearer"}"#
        try await storage.set(legacyToken, for: legacyKey)
        try await storage.set(canonicalToken, for: canonicalKey)
        await OAuthDiscovery.shared.reset(for: rootIssuer)
        MarfaAuthStubURLProtocol.reset(with: [discoveryCanned(for: rootIssuer)])
        let auth = MarfaAuth(
            issuer: rootIssuer,
            clientId: clientId,
            redirectURI: redirectURI,
            scopes: scopes,
            storage: storage,
            urlSession: makeStubbedSession()
        )

        let provider = try #require(await auth.restore())
        #expect(try await provider.currentToken().accessToken == "canonical")
        #expect(await storage.peek(account: canonicalKey) == canonicalToken)
        #expect(await storage.peek(account: legacyKey) == legacyToken)
    }
}

#endif
