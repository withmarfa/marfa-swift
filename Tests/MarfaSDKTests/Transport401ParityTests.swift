import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// Every transport path recovers from a 401 the same way, and none of them
/// turns the recovery into a token-endpoint storm.
///
/// The gaps this pins were all found by probing rather than by reading, and
/// each one had shipped:
///
/// - **`rawUpload` had no 401 handling at all.** It backs blob upload and the
///   sync engine, so a rotated credential ended an attachment upload in a
///   sign-out while the very same client recovered on every other call.
/// - **`eventStream` had none either.** A live subscription was the one place
///   a recoverable 401 was terminal.
/// - **`RetryPolicy.none` broke the path outright.** The recovery lived inside
///   `for attempt in 1...maxAttempts` and reached it with `continue`, so with
///   the public, documented `RetryPolicy.none` (`maxAttempts == 1`) the
///   `continue` left the loop. The refresh token had already been spent, the
///   retry never fired, and the caller got a `NetworkError` for an auth
///   failure — strictly worse than having no recovery. No test drove
///   `RetryPolicy.none`, which is exactly why it survived.
/// - **No storm latch.** Ten requests against a server that refuses every
///   token produced ten exchanges and twenty API calls, where the TypeScript
///   SDK stands the mechanism down after one failed recovery.
///
/// A separate suite from `Transport401StoredProviderTests` because that one
/// proves the mechanism on `rawRequest`; this one proves the mechanism is the
/// same everywhere. Both drive the real `StoredTokenProvider`, never a mock
/// that hands back a fresh token on every call — such a mock passes even when
/// the path is broken, because the defect is that the broken path re-reads the
/// *same* stored token.
final class ParityStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct TokenResponse {
        var statusCode: Int
        var headers: [String: String]
        var body: Data
    }

    private static let lock = NSLock()

    nonisolated(unsafe) private static var revokedBearers: Set<String> = []
    /// When true the API side answers 401 to every bearer, whatever it is.
    /// This is the shape the latch exists for: a request failing for some
    /// reason a new credential cannot fix.
    nonisolated(unsafe) private static var refuseEverything = false
    nonisolated(unsafe) private static var tokenResponses: [TokenResponse] = []
    nonisolated(unsafe) private static var apiAuthHeaders: [String] = []
    nonisolated(unsafe) private static var tokenRequestCount = 0

    static func reset(
        revoked: Set<String> = [],
        refuseEverything: Bool = false,
        tokenResponses: [TokenResponse] = []
    ) {
        lock.lock(); defer { lock.unlock() }
        revokedBearers = revoked
        self.refuseEverything = refuseEverything
        self.tokenResponses = tokenResponses
        apiAuthHeaders = []
        tokenRequestCount = 0
    }

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
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

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
        let refuseAll = Self.refuseEverything
        let revoked = Self.revokedBearers
        Self.lock.unlock()

        let presented = bearer.replacingOccurrences(of: "Bearer ", with: "")
        let refused = refuseAll || revoked.contains(presented)
        let status = refused ? 401 : 200
        let body = refused
            ? Data(#"{"error":{"code":"unauthorized","message":"nope"}}"#.utf8)
            : Data("{}".utf8)

        guard
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func serveTokenExchange() {
        Self.lock.lock()
        Self.tokenRequestCount += 1
        // The last response repeats, so a test that forces several exchanges
        // does not have to enumerate one per attempt.
        let response =
            Self.tokenResponses.count > 1
            ? Self.tokenResponses.removeFirst()
            : Self.tokenResponses.first
        Self.lock.unlock()

        guard
            let response,
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )
        else { return }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private let parityTokenKey = "marfa.auth.tokens:transport-401-parity"
private let parityBaseURL = URL(string: "https://parity.test")!
private let parityTokenEndpoint = URL(string: "https://parity.test/auth/oauth2/token")!

private func parityStubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ParityStubURLProtocol.self]
    return URLSession(configuration: config)
}

private func parityProvider(storage: any SecureStorage) -> StoredTokenProvider {
    StoredTokenProvider(
        storage: storage,
        storageKey: parityTokenKey,
        tokenEndpoint: parityTokenEndpoint,
        clientId: "client-parity",
        urlSession: parityStubbedSession(),
        retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0, jitter: 0)
    )
}

private func parityTransport(
    provider: any TokenProvider,
    retryPolicy: RetryPolicy = RetryPolicy(
        maxAttempts: 3, baseDelay: 0, maxDelay: 0, jitter: 0
    )
) -> URLSessionTransport {
    let configuration = ClientConfiguration(
        url: parityBaseURL,
        tokenProvider: provider,
        retryPolicy: retryPolicy
    )
    return URLSessionTransport(
        configuration: configuration, protocolClasses: [ParityStubURLProtocol.self]
    )
}

/// An hour of clock life left, so the proactive refresh window never fires and
/// a 401 is the only thing that can reveal the token is dead.
private func parityLiveToken(access: String, refresh: String) -> Token {
    Token(
        accessToken: access,
        tokenType: "Bearer",
        refreshToken: refresh,
        idToken: nil,
        expiresAt: Date(timeIntervalSinceNow: 3600),
        scopes: []
    )
}

private func parityRotation(
    access: String,
    refresh: String
) -> ParityStubURLProtocol.TokenResponse {
    .init(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(
            #"{"access_token":"\#(access)","token_type":"bearer","expires_in":3600,"refresh_token":"\#(refresh)"}"#
                .utf8
        )
    )
}

/// One revoked credential, one rotation waiting, ready to call.
private func parityFixture() async throws -> (StoredTokenProvider, URLSessionTransport)
{
    ParityStubURLProtocol.reset(
        revoked: ["revoked"],
        tokenResponses: [parityRotation(access: "rotated", refresh: "rt-2")]
    )
    let provider = parityProvider(storage: InMemoryKeychain())
    try await provider.store(parityLiveToken(access: "revoked", refresh: "rt-1"))
    return (provider, parityTransport(provider: provider))
}

@Suite("Every transport path recovers from a 401 alike", .serialized)
struct Transport401ParityTests {

    // MARK: - The paths that had no recovery at all

    @Test("REGRESSION: rawUpload refreshes and retries instead of returning the 401")
    func rawUploadRecovers() async throws {
        let (_, transport) = try await parityFixture()

        let (_, response) = try await transport.rawUpload(
            method: .post,
            path: "/blobs",
            body: Data("bytes".utf8),
            contentType: "application/octet-stream",
            query: nil,
            onBytesSent: { _, _ in }
        )

        #expect(response.statusCode == 200)
        #expect(
            ParityStubURLProtocol.recordedAPIBearers()
                == ["Bearer revoked", "Bearer rotated"]
        )
        #expect(ParityStubURLProtocol.tokenRequests() == 1)
    }

    @Test("REGRESSION: eventStream refreshes and retries instead of throwing")
    func eventStreamRecovers() async throws {
        let (_, transport) = try await parityFixture()

        // Draining is enough: the assertion is about opening the stream, and
        // the stub closes it immediately.
        let stream = transport.eventStream(path: "/events", query: nil, lastEventID: nil)
        for try await _ in stream {}

        #expect(
            ParityStubURLProtocol.recordedAPIBearers()
                == ["Bearer revoked", "Bearer rotated"]
        )
        #expect(ParityStubURLProtocol.tokenRequests() == 1)
    }

    // MARK: - The policy that broke the path

    @Test("REGRESSION: RetryPolicy.none still recovers, rather than spending the refresh for nothing")
    func retryPolicyNoneRecovers() async throws {
        ParityStubURLProtocol.reset(
            revoked: ["revoked"],
            tokenResponses: [parityRotation(access: "rotated", refresh: "rt-2")]
        )
        let provider = parityProvider(storage: InMemoryKeychain())
        try await provider.store(parityLiveToken(access: "revoked", refresh: "rt-1"))
        // The public, documented no-retry policy. Its `maxAttempts` of 1 left
        // the old loop with no iteration for the retry to land in.
        let transport = parityTransport(provider: provider, retryPolicy: .none)

        _ =
            try await transport.request(
                method: .get, path: "/items", body: nil, query: nil
            ) as EmptyResponse

        #expect(
            ParityStubURLProtocol.recordedAPIBearers()
                == ["Bearer revoked", "Bearer rotated"]
        )
        #expect(ParityStubURLProtocol.tokenRequests() == 1)
    }

    @Test("a credential correction does not consume a transient-retry attempt")
    func recoveryDoesNotSpendTheRetryBudget() async throws {
        // Two things have to fit inside one call: the 401 recovery, and the
        // 500 retries the policy actually budgets for. If the recovery is
        // drawn from the same budget then one of them goes short, which is the
        // shape the old loop had.
        ParityStubURLProtocol.reset(
            revoked: ["revoked"],
            tokenResponses: [parityRotation(access: "rotated", refresh: "rt-2")]
        )
        let provider = parityProvider(storage: InMemoryKeychain())
        try await provider.store(parityLiveToken(access: "revoked", refresh: "rt-1"))
        let transport = parityTransport(
            provider: provider,
            retryPolicy: RetryPolicy(maxAttempts: 2, baseDelay: 0, maxDelay: 0, jitter: 0)
        )

        _ =
            try await transport.request(
                method: .get, path: "/items", body: nil, query: nil
            ) as EmptyResponse

        // Both attempts still available after the recovery: exactly two API
        // calls, the refused one and the corrected one.
        #expect(ParityStubURLProtocol.apiRequests() == 2)
        #expect(ParityStubURLProtocol.tokenRequests() == 1)
    }

    // MARK: - The storm latch

    @Test("REGRESSION: a server that refuses every token stops earning refreshes")
    func refusingServerDoesNotBecomeATokenStorm() async throws {
        // Not a staleness problem: the server refuses a credential it has
        // never seen, so renewing again only adds token-endpoint traffic to a
        // request that is failing for another reason. Before the latch, ten
        // requests produced ten exchanges and twenty API calls.
        ParityStubURLProtocol.reset(
            refuseEverything: true,
            tokenResponses: [parityRotation(access: "fresh", refresh: "rt-next")]
        )
        let provider = parityProvider(storage: InMemoryKeychain())
        try await provider.store(parityLiveToken(access: "original", refresh: "rt-1"))
        let transport = parityTransport(provider: provider)

        for _ in 0..<10 {
            _ =
                try? await transport.request(
                    method: .get, path: "/items", body: nil, query: nil
                ) as EmptyResponse
        }

        // One recovery is attempted and fails to help; the latch then stands
        // the mechanism down, so the remaining nine calls spend nothing.
        #expect(ParityStubURLProtocol.tokenRequests() == 1)
        #expect(ParityStubURLProtocol.apiRequests() == 11)
    }

    @Test("the latch is shared across paths, not held per path")
    func latchIsSharedAcrossPaths() async throws {
        // Three separate paths reaching the same transport must not each get
        // their own free recovery attempt, or the latch bounds nothing.
        ParityStubURLProtocol.reset(
            refuseEverything: true,
            tokenResponses: [parityRotation(access: "fresh", refresh: "rt-next")]
        )
        let provider = parityProvider(storage: InMemoryKeychain())
        try await provider.store(parityLiveToken(access: "original", refresh: "rt-1"))
        let transport = parityTransport(provider: provider)

        _ =
            try? await transport.request(
                method: .get, path: "/items", body: nil, query: nil
            ) as EmptyResponse
        _ = try? await transport.rawUpload(
            method: .post,
            path: "/blobs",
            body: Data("bytes".utf8),
            contentType: "application/octet-stream",
            query: nil,
            onBytesSent: { _, _ in }
        )
        let stream = transport.eventStream(path: "/events", query: nil, lastEventID: nil)
        _ = try? await { () async throws in for try await _ in stream {} }()

        #expect(ParityStubURLProtocol.tokenRequests() == 1)
    }

    @Test("a healthy response releases the latch")
    func healthyTrafficReleasesTheLatch() async throws {
        // Matches the TypeScript SDK, deliberately: any non-401 clears the
        // suppression, so recovery attempts are bounded one-to-one with
        // failures rather than latched for the client's whole lifetime. Only a
        // non-401 can release it, which is why the healthy call in the middle
        // has to actually succeed.
        ParityStubURLProtocol.reset(
            refuseEverything: true,
            tokenResponses: [parityRotation(access: "second", refresh: "rt-2")]
        )
        let provider = parityProvider(storage: InMemoryKeychain())
        try await provider.store(parityLiveToken(access: "original", refresh: "rt-1"))
        let transport = parityTransport(provider: provider)

        // Engage the latch: the recovery runs, rotates to "second", and the
        // retry is refused too.
        _ =
            try? await transport.request(
                method: .get, path: "/items", body: nil, query: nil
            ) as EmptyResponse
        #expect(ParityStubURLProtocol.tokenRequests() == 1)

        // A call the server accepts. This is the only thing that can release
        // the latch, and it must spend no exchange of its own.
        ParityStubURLProtocol.reset()
        _ =
            try await transport.request(
                method: .get, path: "/items", body: nil, query: nil
            ) as EmptyResponse
        #expect(ParityStubURLProtocol.recordedAPIBearers() == ["Bearer second"])
        #expect(ParityStubURLProtocol.tokenRequests() == 0)

        // Released, so a genuine staleness 401 earns a fresh recovery again.
        ParityStubURLProtocol.reset(
            revoked: ["second"],
            tokenResponses: [parityRotation(access: "third", refresh: "rt-3")]
        )
        _ =
            try await transport.request(
                method: .get, path: "/items", body: nil, query: nil
            ) as EmptyResponse
        #expect(ParityStubURLProtocol.tokenRequests() == 1)
        #expect(
            ParityStubURLProtocol.recordedAPIBearers()
                == ["Bearer second", "Bearer third"]
        )
    }
}
