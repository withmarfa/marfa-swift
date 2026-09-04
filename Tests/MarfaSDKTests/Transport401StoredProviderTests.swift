import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// URLProtocol stub local to this suite — URLProtocol subclasses must sit at
/// file scope, and sharing one across suites leaks state under
/// `swift test --parallel`.
///
/// Unlike the queue-driven stubs elsewhere, the API side answers by rule:
/// any bearer in ``revokedBearers`` gets a 401, everything else a 200. A
/// queue can't model this, because the point of the suite is concurrent
/// callers whose request order is not deterministic.
final class StoredProvider401StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct TokenResponse {
        var statusCode: Int
        var headers: [String: String]
        var body: Data
    }

    private static let lock = NSLock()

    /// Access tokens the server has revoked server-side. They are still
    /// within their clock validity, so nothing but a 401 reveals them.
    nonisolated(unsafe) private static var revokedBearers: Set<String> = []
    nonisolated(unsafe) private static var tokenResponses: [TokenResponse] = []
    /// Held open so concurrent callers pile up behind one exchange; without
    /// it the first refresh can finish before the others start, which makes
    /// a single-flight assertion vacuous.
    nonisolated(unsafe) private static var tokenResponseDelay: TimeInterval = 0
    nonisolated(unsafe) private static var apiAuthHeaders: [String] = []
    nonisolated(unsafe) private static var tokenRequestCount = 0

    static func reset(
        revoked: Set<String>,
        tokenResponses: [TokenResponse],
        tokenDelay: TimeInterval = 0
    ) {
        lock.lock(); defer { lock.unlock() }
        revokedBearers = revoked
        self.tokenResponses = tokenResponses
        tokenResponseDelay = tokenDelay
        apiAuthHeaders = []
        tokenRequestCount = 0
    }

    /// Every `Authorization` header the API side saw, in arrival order.
    static func recordedAPIBearers() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return apiAuthHeaders
    }

    static func apiRequests() -> Int {
        lock.lock(); defer { lock.unlock() }
        return apiAuthHeaders.count
    }

    static func tokenRequests() -> Int {
        lock.lock(); defer { lock.unlock() }
        return tokenRequestCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path.hasSuffix("/token") == true {
            serveTokenExchange()
        } else {
            serveAPI()
        }
    }

    override func stopLoading() {}

    private func serveAPI() {
        let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""

        Self.lock.lock()
        Self.apiAuthHeaders.append(bearer)
        let revoked = Self.revokedBearers.contains(bearer.replacingOccurrences(of: "Bearer ", with: ""))
        Self.lock.unlock()

        if revoked {
            finish(
                statusCode: 401,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"unauthorized","message":"token revoked"}"#.utf8)
            )
        } else {
            finish(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data("{}".utf8)
            )
        }
    }

    private func serveTokenExchange() {
        Self.lock.lock()
        Self.tokenRequestCount += 1
        let next = Self.tokenResponses.isEmpty ? nil : Self.tokenResponses.removeFirst()
        let delay = Self.tokenResponseDelay
        Self.lock.unlock()

        guard let next else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        finish(statusCode: next.statusCode, headers: next.headers, body: next.body, after: delay)
    }

    private func finish(
        statusCode: Int,
        headers: [String: String],
        body: Data,
        after delay: TimeInterval = 0
    ) {
        let deliver: @Sendable () -> Void = { [weak self] in
            guard let self, let url = self.request.url else { return }
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }

        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
        } else {
            deliver()
        }
    }
}

private let tokenKey = "marfa.auth.tokens:transport-401"
private let apiBaseURL = URL(string: "https://api.test")!
private let tokenEndpoint = URL(string: "https://api.test/auth/oauth2/token")!

private func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StoredProvider401StubURLProtocol.self]
    return URLSession(configuration: config)
}

/// The real provider, not a mock that hands back a new token on every call.
/// A rotating mock passes even when the 401 path is broken, because the
/// broken path's defect is that it re-reads the *same* stored token.
private func makeStoredProvider(storage: any SecureStorage) -> StoredTokenProvider {
    StoredTokenProvider(
        storage: storage,
        storageKey: tokenKey,
        tokenEndpoint: tokenEndpoint,
        clientId: "client-1",
        urlSession: stubbedSession(),
        retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0, jitter: 0)
    )
}

private func makeTransport(provider: any TokenProvider) -> URLSessionTransport {
    let configuration = ClientConfiguration(
        url: apiBaseURL,
        tokenProvider: provider,
        retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0, jitter: 0)
    )
    return URLSessionTransport(
        configuration: configuration, protocolClasses: [StoredProvider401StubURLProtocol.self]
    )
}

/// A token with an hour of clock life left. The proactive refresh window
/// never fires for it, so the only signal that it is dead is a 401.
private func liveToken(access: String, refresh: String) -> Token {
    Token(
        accessToken: access,
        tokenType: "Bearer",
        refreshToken: refresh,
        idToken: nil,
        expiresAt: Date(timeIntervalSinceNow: 3600),
        scopes: []
    )
}

private func rotation(
    access: String,
    refresh: String
) -> StoredProvider401StubURLProtocol.TokenResponse {
    .init(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(
            #"{"access_token":"\#(access)","token_type":"bearer","expires_in":3600,"refresh_token":"\#(refresh)"}"#.utf8
        )
    )
}

private func invalidGrant() -> StoredProvider401StubURLProtocol.TokenResponse {
    .init(
        statusCode: 400,
        headers: ["Content-Type": "application/json"],
        body: Data(#"{"error":"invalid_grant","error_description":"refresh token revoked"}"#.utf8)
    )
}

/// Collects auth events emitted after this call.
///
/// **There is no subscription race to wait out, and there used to be a sleep
/// here that said there was.** `StoredTokenProvider.authEvents` registers its
/// continuation synchronously inside the `AsyncStream` build closure — which
/// runs when the stream is *created*, on the line below, before the collecting
/// task exists. The provider's own comment records that this was made
/// synchronous deliberately, because deferring it onto a `Task` let an emit
/// land before the subscribe and past events are not replayed.
///
/// So the window closes at `provider.authEvents`, not at the first `await`,
/// and a sleep after it waits on nothing while claiming to cover an actor hop
/// the code does not take.
private func collectingAuthEvents(
    _ provider: StoredTokenProvider
) -> Task<[AuthEvent], Never> {
    let stream = provider.authEvents
    return Task { () -> [AuthEvent] in
        var seen: [AuthEvent] = []
        for await event in stream { seen.append(event) }
        return seen
    }
}

@Suite("Transport 401 against the real stored-token provider", .serialized)
struct Transport401StoredProviderTests {

    // MARK: - The under-refresh gap

    @Test("a 401 on a clock-valid token refreshes the grant instead of signing out")
    func revokedButUnexpiredTokenRecovers() async throws {
        StoredProvider401StubURLProtocol.reset(
            revoked: ["revoked"],
            tokenResponses: [rotation(access: "rotated", refresh: "rt-2")]
        )
        let storage = InMemoryKeychain()
        let provider = makeStoredProvider(storage: storage)
        try await provider.store(liveToken(access: "revoked", refresh: "rt-1"))
        let transport = makeTransport(provider: provider)

        // Revoked server-side but not yet expired by the clock: the
        // proactive window can't see it, so recovery depends entirely on
        // the 401 path forcing an exchange.
        _ = try await transport.request(
            method: .get, path: "/items", body: nil, query: nil
        ) as EmptyResponse

        #expect(
            StoredProvider401StubURLProtocol.recordedAPIBearers()
                == ["Bearer revoked", "Bearer rotated"]
        )
        #expect(StoredProvider401StubURLProtocol.tokenRequests() == 1)

        // The rotated pair must be persisted, or the next launch replays a
        // superseded refresh token and trips reuse detection.
        let raw = try #require(try await storage.get(for: tokenKey))
        #expect(raw.contains("rt-2"))
        #expect(!raw.contains("rt-1"))
    }

    // MARK: - Storm protection

    @Test("concurrent 401s collapse onto a single refresh")
    func concurrentRevokedRequestsShareOneRefresh() async throws {
        StoredProvider401StubURLProtocol.reset(
            revoked: ["revoked"],
            tokenResponses: [rotation(access: "rotated", refresh: "rt-2")],
            tokenDelay: 0.15
        )
        let provider = makeStoredProvider(storage: InMemoryKeychain())
        try await provider.store(liveToken(access: "revoked", refresh: "rt-1"))
        let transport = makeTransport(provider: provider)

        // Twenty requests all carry the revoked bearer and all come back
        // 401. Recovering by refreshing per 401 would be the storm again,
        // in the opposite direction.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = try await transport.request(
                        method: .get, path: "/items", body: nil, query: nil
                    ) as EmptyResponse
                }
            }
            try await group.waitForAll()
        }

        #expect(StoredProvider401StubURLProtocol.tokenRequests() == 1)
        let bearers = StoredProvider401StubURLProtocol.recordedAPIBearers()
        #expect(bearers.filter { $0 == "Bearer revoked" }.count == 20)
        #expect(bearers.filter { $0 == "Bearer rotated" }.count == 20)
    }

    @Test("a 401 carrying an already-superseded bearer starts no second refresh")
    func supersededBearerDoesNotRefreshAgain() async throws {
        StoredProvider401StubURLProtocol.reset(
            revoked: ["revoked"],
            tokenResponses: [rotation(access: "rotated", refresh: "rt-2")]
        )
        let provider = makeStoredProvider(storage: InMemoryKeychain())
        let stale = liveToken(access: "revoked", refresh: "rt-1")
        try await provider.store(stale)

        await provider.invalidate(stale)
        #expect(StoredProvider401StubURLProtocol.tokenRequests() == 1)
        #expect(try await provider.currentToken().accessToken == "rotated")

        // A request that left before the rotation lands afterwards and
        // reports the same dead bearer. That credential is already
        // superseded, so there is nothing to exchange: refreshing again
        // would spend the fresh refresh token and, with enough stragglers,
        // rebuild the storm.
        await provider.invalidate(stale)
        #expect(StoredProvider401StubURLProtocol.tokenRequests() == 1)
        #expect(try await provider.currentToken().accessToken == "rotated")
    }

    // MARK: - A dead grant fails fast

    @Test("a rejected refresh token latches after one exchange and stops all traffic")
    func deadRefreshTokenLatches() async throws {
        // Ten refusals queued; only the first may ever be consumed.
        StoredProvider401StubURLProtocol.reset(
            revoked: ["revoked"],
            tokenResponses: Array(repeating: invalidGrant(), count: 10)
        )
        let storage = InMemoryKeychain()
        let provider = makeStoredProvider(storage: storage)
        try await provider.store(liveToken(access: "revoked", refresh: "rt-dead"))
        let transport = makeTransport(provider: provider)
        let collector = collectingAuthEvents(provider)

        await #expect(throws: OAuthError.self) {
            _ = try await transport.request(
                method: .get, path: "/items", body: nil, query: nil
            ) as EmptyResponse
        }

        // Every later call must fail from the latch, not from another round
        // trip — on the API side as well as the token endpoint, since the
        // transport awaits the provider before it opens a socket.
        for _ in 0..<25 {
            await #expect(throws: OAuthError.self) {
                _ = try await transport.request(
                    method: .get, path: "/items", body: nil, query: nil
                ) as EmptyResponse
            }
        }

        #expect(StoredProvider401StubURLProtocol.tokenRequests() == 1)
        #expect(StoredProvider401StubURLProtocol.apiRequests() == 1)
        #expect(try await storage.get(for: tokenKey) == nil)

        collector.cancel()
        let events = await collector.value
        #expect(events == [.signedOut(reason: .refreshTokenRejected)])
    }
}
