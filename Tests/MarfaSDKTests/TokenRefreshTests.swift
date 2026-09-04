import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// URLProtocol stub local to this suite — the other suites keep their own,
/// because URLProtocol subclasses must sit at file scope and sharing one
/// across suites leaks state under `swift test --parallel`.
final class TokenRefreshStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Canned {
        var statusCode: Int
        var headers: [String: String]
        var body: Data
    }

    nonisolated(unsafe) static var canned: [Canned] = []
    nonisolated(unsafe) static var requestCount = 0
    /// Held open so concurrent callers can pile up behind one exchange —
    /// without a delay the first refresh may finish before the others even
    /// start, which would make the single-flight assertion vacuous.
    nonisolated(unsafe) static var responseDelay: TimeInterval = 0
    private static let lock = NSLock()

    static func reset(with responses: [Canned], delay: TimeInterval = 0) {
        lock.lock(); defer { lock.unlock() }
        canned = responses
        requestCount = 0
        responseDelay = delay
    }

    static func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let next = Self.canned.isEmpty ? nil : Self.canned.removeFirst()
        let delay = Self.responseDelay
        Self.lock.unlock()

        guard let next else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let deliver: @Sendable () -> Void = { [weak self] in
            guard let self, let url = self.request.url else { return }
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: next.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: next.headers
            ) else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: next.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }

        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { deliver() }
        } else {
            deliver()
        }
    }

    override func stopLoading() {}
}

private struct StorageWriteFailure: Error {}

/// Storage whose writes fail on demand, to prove a failed persist never
/// leaves the in-memory cache holding a token that disk doesn't have.
private actor FailingWriteStorage: SecureStorage {
    private var values: [String: String] = [:]
    private var failWrites = false

    func startFailingWrites() { failWrites = true }

    func get(for key: String) async throws -> String? { values[key] }

    func set(_ value: String, for key: String) async throws {
        if failWrites { throw StorageWriteFailure() }
        values[key] = value
    }

    func delete(for key: String) async throws { values.removeValue(forKey: key) }
}

private let tokenKey = "marfa.auth.tokens:test"

private func makeProvider(
    storage: any SecureStorage,
    maxAttempts: Int = 3
) -> StoredTokenProvider {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TokenRefreshStubURLProtocol.self]
    return StoredTokenProvider(
        storage: storage,
        storageKey: tokenKey,
        tokenEndpoint: URL(string: "https://example.test/auth/oauth2/token")!,
        clientId: "client-1",
        urlSession: URLSession(configuration: config),
        // Zero delays keep the suite fast; the retry *decision* is what's
        // under test, not the wall-clock backoff.
        retryPolicy: RetryPolicy(maxAttempts: maxAttempts, baseDelay: 0, maxDelay: 0, jitter: 0)
    )
}

private func expiredToken(refresh: String = "rt-1") -> Token {
    Token(
        accessToken: "stale",
        tokenType: "Bearer",
        refreshToken: refresh,
        idToken: nil,
        expiresAt: Date(timeIntervalSinceNow: -60),
        scopes: ["core.note:read"]
    )
}

private func successBody(access: String, refresh: String?) -> Data {
    var fields = #""access_token":"\#(access)","token_type":"bearer","expires_in":3600,"scope":"core.note:read""#
    if let refresh { fields += #","refresh_token":"\#(refresh)""# }
    return Data("{\(fields)}".utf8)
}

private func oauthErrorBody(_ code: String) -> Data {
    Data(#"{"error":"\#(code)","error_description":"nope"}"#.utf8)
}

/// Collects auth events.
///
/// No sleep. `authEvents` registers the subscriber synchronously, so taking
/// the stream is enough — the pause here used to exist because registration
/// was deferred onto a `Task`, which is the very window that lost a
/// `signedOut` to a caller who subscribed and then read a token.
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

@Suite("OAuth refresh: single-flight, terminal latch, and backoff", .serialized, .timeLimit(.minutes(1)))
struct TokenRefreshTests {

    // MARK: - The root cause

    @Test("concurrent callers share one refresh instead of racing the rotation")
    func concurrentRefreshIsSingleFlight() async throws {
        TokenRefreshStubURLProtocol.reset(
            with: [.init(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: successBody(access: "fresh", refresh: "rt-2")
            )],
            delay: 0.15
        )
        let storage = InMemoryKeychain()
        let provider = makeProvider(storage: storage)
        try await provider.store(expiredToken())

        // Twenty callers all observe the same stale token. Without
        // coalescing, each starts its own exchange, the first rotates the
        // refresh token, and the other nineteen replay a superseded one —
        // which the server treats as reuse and answers by killing the grant.
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask { try await provider.currentToken().accessToken }
            }
            var results: [String] = []
            for try await token in group { results.append(token) }
            return results
        }

        #expect(tokens.count == 20)
        #expect(tokens.allSatisfy { $0 == "fresh" })
        #expect(TokenRefreshStubURLProtocol.count() == 1)
    }

    // MARK: - Terminal failures latch

    @Test("token_reuse_detected signs out once and never calls the network again")
    func reuseDetectedLatches() async throws {
        // Ten responses queued; only the first should ever be consumed.
        TokenRefreshStubURLProtocol.reset(with: Array(repeating: .init(
            statusCode: 400,
            headers: ["Content-Type": "application/json"],
            body: oauthErrorBody("token_reuse_detected")
        ), count: 10))
        let storage = InMemoryKeychain()
        let provider = makeProvider(storage: storage)
        try await provider.store(expiredToken())
        let collector = collectingAuthEvents(provider)

        await #expect(throws: OAuthError.self) {
            _ = try await provider.currentToken()
        }

        // The storm shape: every later call must fail from the latch, not
        // from another round trip.
        for _ in 0..<25 {
            await #expect(throws: OAuthError.self) {
                _ = try await provider.currentToken()
            }
        }
        #expect(TokenRefreshStubURLProtocol.count() == 1)
        #expect(try await storage.get(for: tokenKey) == nil)

        collector.cancel()
        let events = await collector.value
        #expect(events.first == .signedOut(reason: .reuseDetected))
    }

    @Test("invalid_grant signs out as a rejected refresh token")
    func invalidGrantLatches() async throws {
        TokenRefreshStubURLProtocol.reset(with: [.init(
            statusCode: 400,
            headers: ["Content-Type": "application/json"],
            body: oauthErrorBody("invalid_grant")
        )])
        let provider = makeProvider(storage: InMemoryKeychain())
        try await provider.store(expiredToken())
        let collector = collectingAuthEvents(provider)

        await #expect(throws: OAuthError.self) {
            _ = try await provider.currentToken()
        }

        collector.cancel()
        let events = await collector.value
        #expect(events.first == .signedOut(reason: .refreshTokenRejected))
    }

    @Test("a stored token revives a latched provider")
    func storeClearsTheLatch() async throws {
        TokenRefreshStubURLProtocol.reset(with: [.init(
            statusCode: 400,
            headers: ["Content-Type": "application/json"],
            body: oauthErrorBody("invalid_grant")
        )])
        let provider = makeProvider(storage: InMemoryKeychain())
        try await provider.store(expiredToken())
        await #expect(throws: OAuthError.self) { _ = try await provider.currentToken() }

        // Re-authenticating hands the provider a fresh grant.
        let fresh = Token(
            accessToken: "after-signin",
            tokenType: "Bearer",
            refreshToken: "rt-new",
            idToken: nil,
            expiresAt: Date(timeIntervalSinceNow: 3600),
            scopes: []
        )
        try await provider.store(fresh)
        #expect(try await provider.currentToken().accessToken == "after-signin")
    }

    // MARK: - Transient failures do not end the session

    @Test("429 retries within bounds and keeps the session")
    func rateLimitedRefreshRetries() async throws {
        TokenRefreshStubURLProtocol.reset(with: [
            .init(statusCode: 429, headers: ["Retry-After": "0"], body: oauthErrorBody("rate_limited")),
            .init(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: successBody(access: "fresh", refresh: "rt-2")
            )
        ])
        let storage = InMemoryKeychain()
        let provider = makeProvider(storage: storage)
        try await provider.store(expiredToken())
        let collector = collectingAuthEvents(provider)

        #expect(try await provider.currentToken().accessToken == "fresh")
        #expect(TokenRefreshStubURLProtocol.count() == 2)

        collector.cancel()
        #expect(await collector.value.isEmpty)
    }

    @Test("exhausting retries on 429 throws but leaves the session intact")
    func rateLimitExhaustionDoesNotSignOut() async throws {
        TokenRefreshStubURLProtocol.reset(with: Array(repeating: .init(
            statusCode: 429,
            headers: ["Retry-After": "0"],
            body: oauthErrorBody("rate_limited")
        ), count: 5))
        let storage = InMemoryKeychain()
        let provider = makeProvider(storage: storage, maxAttempts: 3)
        try await provider.store(expiredToken())
        let collector = collectingAuthEvents(provider)

        await #expect(throws: OAuthError.self) { _ = try await provider.currentToken() }

        // Bounded by the policy, not unbounded like the original loop.
        #expect(TokenRefreshStubURLProtocol.count() == 3)
        // A rate limit is not a revoked grant: the tokens must survive so the
        // next attempt can succeed rather than forcing the user to sign in.
        #expect(try await storage.get(for: tokenKey) != nil)
        collector.cancel()
        #expect(await collector.value.isEmpty)
    }

    // MARK: - Rotation persistence

    @Test("a rotated refresh token is persisted")
    func rotationIsPersisted() async throws {
        TokenRefreshStubURLProtocol.reset(with: [.init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: successBody(access: "fresh", refresh: "rt-2")
        )])
        let storage = InMemoryKeychain()
        let provider = makeProvider(storage: storage)
        try await provider.store(expiredToken(refresh: "rt-1"))

        _ = try await provider.currentToken()

        let raw = try #require(try await storage.get(for: tokenKey))
        #expect(raw.contains("rt-2"))
        #expect(!raw.contains("rt-1"))
    }

    @Test("a response omitting refresh_token keeps the previous one")
    func missingRotationKeepsPreviousRefreshToken() async throws {
        TokenRefreshStubURLProtocol.reset(with: [.init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: successBody(access: "fresh", refresh: nil)
        )])
        let storage = InMemoryKeychain()
        let provider = makeProvider(storage: storage)
        try await provider.store(expiredToken(refresh: "rt-1"))

        _ = try await provider.currentToken()

        let raw = try #require(try await storage.get(for: tokenKey))
        // Losing the refresh token here would strand the session with no way
        // to refresh at all.
        #expect(raw.contains("rt-1"))
    }

    // MARK: - Persistence ordering

    @Test("a failed persist does not leave the cache ahead of storage")
    func failedPersistDoesNotDesyncCache() async throws {
        TokenRefreshStubURLProtocol.reset(with: [.init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: successBody(access: "fresh", refresh: "rt-2")
        )])
        let storage = FailingWriteStorage()
        let provider = makeProvider(storage: storage)
        try await provider.store(expiredToken(refresh: "rt-1"))
        await storage.startFailingWrites()

        await #expect(throws: (any Error).self) { _ = try await provider.currentToken() }

        // Storage still holds the old pair. If the cache had been updated
        // first, the next launch would reload the superseded refresh token
        // and trip reuse detection.
        let raw = try #require(try await storage.get(for: tokenKey))
        #expect(raw.contains("rt-1"))
        #expect(!raw.contains("rt-2"))
    }
}
