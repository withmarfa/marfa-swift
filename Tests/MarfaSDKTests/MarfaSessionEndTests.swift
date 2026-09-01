import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// URLProtocol stub local to this suite, per the convention the other
/// network-touching auth suites follow.
///
/// It answers the **path-aware** well-known URL, which is the whole point here:
/// `MarfaSession.end` derives the issuer as `<server>/auth`, so discovery asks
/// for `/.well-known/oauth-authorization-server/auth` and RFC 8414 §3.3 refuses
/// a document naming anything else. A stub answering only at the root would
/// make every revocation test fail for a reason unrelated to what it tests.
final class SessionEndStubURLProtocol: URLProtocol, @unchecked Sendable {
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

        let wellKnown = "/.well-known/oauth-authorization-server"
        var responseBody = Data()
        if let url = request.url,
           url.path.hasPrefix(wellKnown),
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            // Everything after the well-known prefix is the issuer's own path,
            // so the document must name origin + that.
            let issuerPath = String(url.path.dropFirst(wellKnown.count))
            components.path = ""
            let origin = components.url?.absoluteString ?? ""
            let issuer = origin + issuerPath
            responseBody = Data("""
            {"issuer":"\(issuer)","authorization_endpoint":"\(origin)/auth/oauth2/authorize","token_endpoint":"\(origin)/auth/oauth2/token","revocation_endpoint":"\(origin)/auth/oauth2/revoke","device_authorization_endpoint":"\(origin)/auth/device"}
            """.utf8)
        }

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SessionEndStubURLProtocol.self]
    return URLSession(configuration: config)
}

@Suite("Ending a session in one call", .serialized, .timeLimit(.minutes(1)))
struct MarfaSessionEndTests {

    /// Seed all four accounts the SDK can hold for one issuer and client.
    private func seedEverySpelling(
        _ storage: InMemoryKeychain,
        issuer: URL,
        clientId: String
    ) async throws {
        let canonical = OAuthIssuer.normalize(issuer)
        try await storage.set("t", for: OAuthIssuer.storageKey(
            kind: "tokens", issuer: canonical, clientId: clientId))
        try await storage.set("p", for: OAuthIssuer.storageKey(
            kind: "pending", issuer: canonical, clientId: clientId))
        try await storage.set("lt", for: OAuthIssuer.legacyStorageKey(
            kind: "tokens", issuer: canonical, clientId: clientId))
        try await storage.set("lp", for: OAuthIssuer.legacyStorageKey(
            kind: "pending", issuer: canonical, clientId: clientId))
    }

    private func remaining(
        _ storage: InMemoryKeychain,
        issuer: URL,
        clientId: String
    ) async throws -> [String] {
        let canonical = OAuthIssuer.normalize(issuer)
        var left: [String] = []
        for (name, key) in [
            ("tokens.v2", OAuthIssuer.storageKey(kind: "tokens", issuer: canonical, clientId: clientId)),
            ("pending.v2", OAuthIssuer.storageKey(kind: "pending", issuer: canonical, clientId: clientId)),
            ("tokens.legacy", OAuthIssuer.legacyStorageKey(kind: "tokens", issuer: canonical, clientId: clientId)),
            ("pending.legacy", OAuthIssuer.legacyStorageKey(kind: "pending", issuer: canonical, clientId: clientId)),
        ] {
            if try await storage.get(for: key) != nil { left.append(name) }
        }
        return left
    }

    @Test("it takes the server URL and clears what the derived issuer keyed")
    func derivesTheIssuerFromTheServerURL() async throws {
        let serverURL = uniqueServerURL("session-end-derive")
        let issuer = OAuthDiscovery.issuer(forServer: serverURL)
        let storage = InMemoryKeychain()
        try await seedEverySpelling(storage, issuer: issuer, clientId: "cid")

        // The caller hands over the *server* URL, which is the value it has.
        _ = try await MarfaSession.end(
            serverURL: serverURL, clientId: "cid", storage: storage
        )

        // This is the trap the call exists to close. Credentials are keyed on
        // the derived issuer, and every consumer of this SDK reached for the
        // bare host — where a sign-in fails loudly and a clear succeeds having
        // deleted nothing, leaving a working credential on a device the person
        // believes is signed out.
        let left = try await remaining(storage, issuer: issuer, clientId: "cid")
        #expect(left.isEmpty, "still present: \(left)")
    }

    @Test("the bare server URL leaves the live credential behind and reports success")
    func theBareHostMissesTheCurrentAccounts() async throws {
        let serverURL = uniqueServerURL("session-end-bare")
        let issuer = OAuthDiscovery.issuer(forServer: serverURL)
        let storage = InMemoryKeychain()
        try await seedEverySpelling(storage, issuer: issuer, clientId: "cid")

        // What a consumer wrote before this call existed: the server URL passed
        // where an issuer was wanted. It throws nothing and returns normally.
        try await clearCredentialAccounts(
            issuer: serverURL, clientId: "cid", storage: storage
        )

        // And it is worse than clearing nothing, which is why this test is
        // here rather than a simpler one. The legacy spelling is keyed on the
        // *host* alone, so the wrong issuer addresses both legacy accounts and
        // deletes them — while the two current accounts, keyed on the full
        // canonical issuer, survive untouched. The caller sees four successful
        // deletes and is left holding the only credential that still works.
        let left = try await remaining(storage, issuer: issuer, clientId: "cid")
        #expect(Set(left) == ["tokens.v2", "pending.v2"], "left behind: \(left)")
    }

    @Test("it clears with no provider in hand")
    func clearsWithoutAProvider() async throws {
        let serverURL = uniqueServerURL("session-end-offline")
        let issuer = OAuthDiscovery.issuer(forServer: serverURL)
        let storage = InMemoryKeychain()
        try await seedEverySpelling(storage, issuer: issuer, clientId: "cid")

        // The case the existing `clearStoredCredentials` was added for:
        // discovery is unreachable so `restore()` cannot build a provider, and
        // `signOut(_:)` has nothing to act on.
        let result = try await MarfaSession.end(
            serverURL: serverURL, clientId: "cid", storage: storage
        )

        #expect(result == .clearedButNotRevoked)
        let left = try await remaining(storage, issuer: issuer, clientId: "cid")
        #expect(left.isEmpty)
    }

    @Test("it leaves another client's credentials alone")
    func leavesAnotherClientAlone() async throws {
        let serverURL = uniqueServerURL("session-end-isolate")
        let issuer = OAuthDiscovery.issuer(forServer: serverURL)
        let storage = InMemoryKeychain()
        try await seedEverySpelling(storage, issuer: issuer, clientId: "mine")
        try await seedEverySpelling(storage, issuer: issuer, clientId: "theirs")

        _ = try await MarfaSession.end(
            serverURL: serverURL, clientId: "mine", storage: storage
        )

        #expect(try await remaining(storage, issuer: issuer, clientId: "mine").isEmpty)
        #expect(try await remaining(storage, issuer: issuer, clientId: "theirs").count == 4)
    }

    @Test("with a live provider it revokes both tokens and says so")
    func revokesAccessAndRefresh() async throws {
        SessionEndStubURLProtocol.reset()
        let serverURL = uniqueServerURL("session-end-revoke")
        let issuer = OAuthDiscovery.issuer(forServer: serverURL)
        let session = stubbedSession()
        let storage = InMemoryKeychain()
        try await seedEverySpelling(storage, issuer: issuer, clientId: "cid")

        let tokensKey = OAuthIssuer.storageKey(
            kind: "tokens", issuer: OAuthIssuer.normalize(issuer), clientId: "cid")
        let provider = StoredTokenProvider(
            storage: storage,
            storageKey: tokensKey,
            tokenEndpoint: serverURL.appending(path: "auth/oauth2/token"),
            clientId: "cid",
            urlSession: session
        )
        try await provider.store(Token(
            accessToken: "access-1",
            tokenType: "Bearer",
            refreshToken: "refresh-1",
            idToken: nil,
            expiresAt: Date().addingTimeInterval(3600),
            scopes: []
        ))

        let result = try await MarfaSession.end(
            serverURL: serverURL,
            clientId: "cid",
            storage: storage,
            revoking: provider,
            urlSession: session
        )

        #expect(result == .revokedAndCleared)

        let bodies = SessionEndStubURLProtocol.recorded()
            .filter { $0.0.url?.path.contains("revoke") == true }
            .map { String(data: $0.1, encoding: .utf8) ?? "" }
        // Both, not just the access token. A refresh token left live outlives
        // the app that stopped holding it and there is no admin route to it.
        #expect(bodies.contains { $0.contains("token=access-1") })
        #expect(bodies.contains { $0.contains("token=refresh-1") })
        #expect(bodies.allSatisfy { $0.contains("client_id=cid") })

        let left = try await remaining(storage, issuer: issuer, clientId: "cid")
        #expect(left.isEmpty)
    }

    @Test("an unreachable server still clears the device, and reports that it did not revoke")
    func clearsEvenWhenRevocationFails() async throws {
        let serverURL = uniqueServerURL("session-end-unreachable")
        let issuer = OAuthDiscovery.issuer(forServer: serverURL)
        let storage = InMemoryKeychain()
        try await seedEverySpelling(storage, issuer: issuer, clientId: "cid")

        let tokensKey = OAuthIssuer.storageKey(
            kind: "tokens", issuer: OAuthIssuer.normalize(issuer), clientId: "cid")
        // No stub on this session, so discovery cannot resolve and revocation
        // cannot happen.
        let provider = StoredTokenProvider(
            storage: storage,
            storageKey: tokensKey,
            tokenEndpoint: serverURL.appending(path: "auth/oauth2/token"),
            clientId: "cid",
            urlSession: URLSession(configuration: .ephemeral)
        )
        try await provider.store(Token(
            accessToken: "a", tokenType: "Bearer", refreshToken: "r",
            idToken: nil, expiresAt: Date().addingTimeInterval(3600), scopes: []
        ))

        let result = try await MarfaSession.end(
            serverURL: serverURL,
            clientId: "cid",
            storage: storage,
            revoking: provider,
            urlSession: URLSession(configuration: .ephemeral)
        )

        // Giving up local credentials must not depend on reaching the network,
        // so this is a result rather than a thrown error — and it is still
        // worth reporting, because the grant outlives the device.
        #expect(result == .clearedButNotRevoked)
        let left = try await remaining(storage, issuer: issuer, clientId: "cid")
        #expect(left.isEmpty)
    }
}
