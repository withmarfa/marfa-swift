import Testing
import Foundation
@testable import MymeSDK

/// URLProtocol stub local to this suite — the other test suites have
/// their own per-suite stubs (Swift requires URLProtocol subclasses at
/// file scope and inter-suite type sharing leaks state under
/// `swift test --parallel`).
final class RefreshStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Canned {
        var statusCode: Int
        var headers: [String: String]
        var body: Data
    }

    nonisolated(unsafe) static var canned: [Canned] = []
    nonisolated(unsafe) static var recordedAuthHeaders: [String] = []
    private static let lock = NSLock()

    static func reset(with responses: [Canned]) {
        lock.lock(); defer { lock.unlock() }
        canned = responses
        recordedAuthHeaders = []
    }

    static func authHeaders() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedAuthHeaders
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        Self.recordedAuthHeaders.append(auth)
        if Self.canned.isEmpty {
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let next = Self.canned.removeFirst()
        Self.lock.unlock()

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

/// Records `invalidate()` calls and rotates the bearer on each fetch so
/// the test can prove the transport pulls a fresh token after a 401.
private actor RotatingTokenProvider: TokenProvider {
    private var counter = 0
    private var invalidateCount = 0

    func currentToken() async throws -> Token {
        counter += 1
        return Token(
            accessToken: "token-\(counter)",
            tokenType: "Bearer",
            refreshToken: "rt-\(counter)",
            idToken: nil,
            expiresAt: Date(timeIntervalSinceNow: 3600),
            scopes: []
        )
    }

    func invalidate() async {
        invalidateCount += 1
    }

    func snapshot() async -> (issued: Int, invalidated: Int) {
        (counter, invalidateCount)
    }
}

private func makeStubbedTransport(provider: any TokenProvider) -> URLSessionTransport {
    let urlConfig = URLSessionConfiguration.ephemeral
    urlConfig.protocolClasses = [RefreshStubURLProtocol.self]
    let session = URLSession(configuration: urlConfig)
    // The 401-refresh-once mechanism shares the attempt counter with the
    // retry loop, so the policy needs at least two attempts available
    // for the refresh to consume one. Match the SDK's default shape.
    let clientConfig = ClientConfiguration(
        url: URL(string: "http://test")!,
        tokenProvider: provider,
        retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0, jitter: 0)
    )
    return URLSessionTransport(configuration: clientConfig, session: session)
}

@Suite("Transport 401 refresh-once behaviour", .serialized)
struct Transport401RefreshTests {

    @Test("401 then 200 invalidates the provider and retries with a fresh bearer")
    func refreshOnceAndSucceed() async throws {
        RefreshStubURLProtocol.reset(with: [
            .init(statusCode: 401, headers: [:], body: Data()),
            .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"ok":true}"#.utf8))
        ])
        let provider = RotatingTokenProvider()
        let transport = makeStubbedTransport(provider: provider)

        let (data, response) = try await transport.rawRequest(
            method: .get, path: "/items", body: nil, contentType: nil, query: nil
        )

        #expect(response.statusCode == 200)
        #expect(!data.isEmpty)

        let snapshot = await provider.snapshot()
        #expect(snapshot.issued == 2)
        #expect(snapshot.invalidated == 1)

        let headers = RefreshStubURLProtocol.authHeaders()
        #expect(headers.count == 2)
        #expect(headers[0] == "Bearer token-1")
        #expect(headers[1] == "Bearer token-2")
    }

    @Test("a second 401 surfaces as UnauthorizedError without further retries")
    func secondFourOhOneFails() async throws {
        // Three 401s queued — the transport should only attempt twice
        // (the initial call plus one refresh-retry) before raising.
        RefreshStubURLProtocol.reset(with: [
            .init(statusCode: 401, headers: [:], body: Data()),
            .init(statusCode: 401, headers: [:], body: Data(#"{"error":"unauthorized"}"#.utf8)),
            .init(statusCode: 401, headers: [:], body: Data())
        ])
        let provider = RotatingTokenProvider()
        let transport = makeStubbedTransport(provider: provider)

        do {
            _ = try await transport.request(
                method: .get, path: "/items", body: nil, query: nil
            ) as EmptyResponse
            Issue.record("expected UnauthorizedError")
        } catch is UnauthorizedError {
            // expected
        }

        let snapshot = await provider.snapshot()
        #expect(snapshot.issued == 2)
        #expect(snapshot.invalidated == 1)
        // Only two attempts: the original 401 + one refresh-retry. The
        // third canned 401 should be untouched.
        #expect(RefreshStubURLProtocol.authHeaders().count == 2)
    }
}
