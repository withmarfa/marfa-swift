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
private func discoveryCanned() -> MarfaAuthStubURLProtocol.Canned {
    let body = #"""
    {
      "issuer": "https://staging.marfa.so",
      "authorization_endpoint": "https://staging.marfa.so/auth/oauth2/authorize",
      "token_endpoint": "https://staging.marfa.so/auth/oauth2/token",
      "revocation_endpoint": "https://staging.marfa.so/auth/oauth2/revoke",
      "device_authorization_endpoint": "https://staging.marfa.so/auth/device"
    }
    """#
    return .init(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(body.utf8),
        error: nil
    )
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
            authorize: URL(string: "https://staging.marfa.so/auth/oauth2/authorize")!,
            challenge: "challenge-abc",
            state: "state-xyz"
        )

        #expect(url.scheme == "https")
        #expect(url.host == "staging.marfa.so")
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
            authorize: URL(string: "https://staging.marfa.so/auth/oauth2/authorize")!,
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
            tokenEndpoint: URL(string: "https://staging.marfa.so/auth/oauth2/token")!
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
                tokenEndpoint: URL(string: "https://staging.marfa.so/auth/oauth2/token")!
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
        // Match MarfaAuth's tokensKey shape: marfa.auth.tokens:<host>:<clientId>
        let key = "marfa.auth.tokens:\(issuer.host ?? ""):\(clientId)"
        let json = #"{"access_token":"a","expires_at":"2099-01-01T00:00:00Z","scope":"","token_type":"Bearer"}"#
        try await storage.set(json, for: key)

        // restore() runs OAuth discovery to resolve the refresh endpoint.
        MarfaAuthStubURLProtocol.reset(with: [discoveryCanned()])

        let auth = makeAuth(session: makeStubbedSession(), storage: storage)
        let provider = try await auth.restore()

        #expect(provider != nil)
        let token = try await provider!.currentToken()
        #expect(token.accessToken == "a")
    }
}

#endif
