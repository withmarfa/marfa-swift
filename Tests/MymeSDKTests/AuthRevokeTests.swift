#if canImport(AuthenticationServices) && !os(watchOS) && !os(tvOS)

import Testing
import Foundation
import AuthenticationServices
@testable import MymeSDK
import MymeSDKTestSupport

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

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeStubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RevokeStubURLProtocol.self]
    return URLSession(configuration: config)
}

@Suite("MymeAuth sign-out / revoke", .serialized)
@MainActor
struct AuthRevokeTests {

    let issuer = URL(string: "https://staging.myme.so")!
    let clientId = "test-client"
    let tokensKey = "myme.auth.tokens:staging.myme.so:test-client"

    func prepareAuth() async throws -> (MymeAuth, InMemoryKeychain, URLSession) {
        let storage = InMemoryKeychain()
        let session = makeStubbedSession()
        let auth = MymeAuth(
            issuer: issuer,
            clientId: clientId,
            redirectURI: URL(string: "myme-test://auth/callback")!,
            scopes: ["openid"],
            storage: storage,
            urlSession: session
        )
        // Pre-seed storage so signOut can resolve a current token.
        let json = #"""
        {"access_token":"myme_at_aaa","refresh_token":"myme_rt_bbb","expires_at":"2099-01-01T00:00:00Z","scope":"openid","token_type":"Bearer"}
        """#
        try await storage.set(json, for: tokensKey)
        return (auth, storage, session)
    }

    @Test("signOut posts the access and refresh tokens to /auth/revoke with client_id")
    func revokesBothTokens() async throws {
        RevokeStubURLProtocol.reset()
        let (auth, storage, session) = try await prepareAuth()
        let provider = StoredTokenProvider(
            storage: storage,
            storageKey: tokensKey,
            tokenEndpoint: issuer.appendingPathComponent("auth/token"),
            clientId: clientId,
            urlSession: session
        )

        try await auth.signOut(provider)

        let recorded = RevokeStubURLProtocol.recorded()
        // Two POSTs to /auth/revoke: one per token.
        #expect(recorded.count == 2)
        let bodies = recorded.map { (req, body) -> (String, String) in
            (req.url?.path ?? "", String(data: body, encoding: .utf8) ?? "")
        }
        for (path, form) in bodies {
            #expect(path == "/auth/revoke")
            #expect(form.contains("client_id=test-client"))
        }
        // One form body carries the access token, the other the refresh token.
        let combined = bodies.map(\.1).joined(separator: "|")
        #expect(combined.contains("token=myme_at_aaa"))
        #expect(combined.contains("token=myme_rt_bbb"))

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
        let auth = MymeAuth(
            issuer: issuer,
            clientId: clientId,
            redirectURI: URL(string: "myme-test://auth/callback")!,
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
