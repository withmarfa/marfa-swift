#if canImport(AuthenticationServices) && !os(watchOS) && !os(tvOS)

import Testing
import Foundation
import AuthenticationServices
@testable import MarfaSDK
import MarfaSDKTestSupport

/// URLProtocol stub local to this suite — see `Transport401RefreshTests`
/// for the rationale on per-suite scoped stubs.
final class RevokeStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recordedRequests: [(URLRequest, Data)] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        recordedRequests = []
    }

    static func recorded() -> [(URLRequest, Data)] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var bodyData = request.httpBody ?? Data()
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: 4096)
                if read <= 0 { break }
                bodyData.append(buf, count: read)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.recordedRequests.append((request, bodyData))
        Self.lock.unlock()

        // Return a well-known discovery doc for the OAuth discovery
        // probe; otherwise return an empty 200 (the revoke endpoint
        // returns no body on success per RFC 7009 §2.2).
        let responseBody: Data
        if request.url?.path == "/.well-known/oauth-authorization-server" {
            let discovery = #"""
            {"issuer":"https://auth-revoke.example.test","authorization_endpoint":"https://auth-revoke.example.test/auth/oauth2/authorize","token_endpoint":"https://auth-revoke.example.test/auth/oauth2/token","revocation_endpoint":"https://auth-revoke.example.test/auth/oauth2/revoke","device_authorization_endpoint":"https://auth-revoke.example.test/auth/device"}
            """#
            responseBody = Data(discovery.utf8)
        } else {
            responseBody = Data()
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeStubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RevokeStubURLProtocol.self]
    return URLSession(configuration: config)
}

@Suite("MarfaAuth sign-out / revoke", .serialized)
@MainActor
struct AuthRevokeTests {

    /// `signOut` resolves the revoke endpoint through OAuth discovery,
    /// whose cache is process-wide and keyed by origin. A struct suite is
    /// instantiated once per test, so each test gets an origin nobody
    /// else uses and starts cold — no clearing of the shared cache, and
    /// so no interference with suites running alongside this one.
    let issuer = uniqueIssuer("marfa-auth-revoke")
    let clientId = "test-client"
    var tokensKey: String {
        OAuthIssuer.storageKey(kind: "tokens", issuer: issuer, clientId: clientId)
    }

    func prepareAuth() async throws -> (MarfaAuth, InMemoryKeychain, URLSession) {
        let storage = InMemoryKeychain()
        let session = makeStubbedSession()
        let auth = MarfaAuth(
            issuer: issuer,
            clientId: clientId,
            redirectURI: URL(string: "marfa-test://auth/callback")!,
            scopes: ["openid"],
            storage: storage,
            urlSession: session
        )
        // Pre-seed storage so signOut can resolve a current token.
        let json = #"""
        {"access_token":"marfa_at_aaa","refresh_token":"marfa_rt_bbb","expires_at":"2099-01-01T00:00:00Z","scope":"openid","token_type":"Bearer"}
        """#
        try await storage.set(json, for: tokensKey)
        return (auth, storage, session)
    }

    @Test("signOut posts the access and refresh tokens to the discovered revoke endpoint with client_id")
    func revokesBothTokens() async throws {
        RevokeStubURLProtocol.reset()
        let (auth, storage, session) = try await prepareAuth()
        let provider = StoredTokenProvider(
            storage: storage,
            storageKey: tokensKey,
            tokenEndpoint: URL(string: "https://auth-revoke.example.test/auth/oauth2/token")!,
            clientId: clientId,
            urlSession: session
        )

        try await auth.signOut(provider)

        let recorded = RevokeStubURLProtocol.recorded()
        // Two POSTs to the discovered revoke endpoint — one per token.
        // The recorded set also includes the discovery probe(s); we
        // only assert on the revoke calls.
        let revokeCalls = recorded.filter { (req, _) in
            req.url?.path == "/auth/oauth2/revoke"
        }
        #expect(revokeCalls.count == 2)
        let bodies = revokeCalls.map { (_, body) in
            String(data: body, encoding: .utf8) ?? ""
        }
        for form in bodies {
            #expect(form.contains("client_id=test-client"))
        }
        // One form body carries the access token, the other the refresh token.
        let combined = bodies.joined(separator: "|")
        #expect(combined.contains("token=marfa_at_aaa"))
        #expect(combined.contains("token=marfa_rt_bbb"))

        // Local storage cleared.
        let remaining = try await storage.get(for: tokensKey)
        #expect(remaining == nil)
    }

    @Test("signOut clears local storage even when revoke errors")
    func clearsOnRevokeFailure() async throws {
        // Reset to an empty queue; the URLProtocol stub's default canInit
        // returns true but every request will get a 200 by the stub — so
        // to simulate a revoke failure we swap in a fresh stub class that
        // always raises a URL error.
        final class FailingStub: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            }
            override func stopLoading() {}
        }

        let storage = InMemoryKeychain()
        let json = #"""
        {"access_token":"a","refresh_token":"r","expires_at":"2099-01-01T00:00:00Z","scope":"openid","token_type":"Bearer"}
        """#
        try await storage.set(json, for: tokensKey)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingStub.self]
        let session = URLSession(configuration: config)
        let auth = MarfaAuth(
            issuer: issuer,
            clientId: clientId,
            redirectURI: URL(string: "marfa-test://auth/callback")!,
            scopes: ["openid"],
            storage: storage,
            urlSession: session
        )
        let provider = StoredTokenProvider(
            storage: storage,
            storageKey: tokensKey,
            tokenEndpoint: issuer.appendingPathComponent("auth/token"),
            clientId: clientId,
            urlSession: session
        )

        try await auth.signOut(provider)

        // Network revoke failed — local state still cleared so the next
        // sign-in starts clean.
        let remaining = try await storage.get(for: tokensKey)
        #expect(remaining == nil)
    }
}

#endif
