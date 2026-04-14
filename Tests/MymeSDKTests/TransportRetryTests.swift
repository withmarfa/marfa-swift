import Testing
import Foundation
@testable import MymeSDK

/// URLProtocol stub that returns canned responses per request, optionally
/// after a delay, and records each attempt.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    struct CannedResponse {
        var statusCode: Int
        var headers: [String: String]
        var body: Data
        var delay: TimeInterval
        var error: URLError?

        static func ok(status: Int = 200, body: String = "{}", headers: [String: String] = [:]) -> CannedResponse {
            .init(statusCode: status, headers: headers, body: Data(body.utf8), delay: 0, error: nil)
        }

        static func error(_ code: URLError.Code) -> CannedResponse {
            .init(statusCode: 0, headers: [:], body: Data(), delay: 0, error: URLError(code))
        }
    }

    // Shared state guarded by lock.
    nonisolated(unsafe) static var cannedResponses: [CannedResponse] = []
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []
    private static let stateLock = NSLock()

    static func reset(with responses: [CannedResponse]) {
        stateLock.lock(); defer { stateLock.unlock() }
        cannedResponses = responses
        recordedRequests = []
    }

    static func recorded() -> [URLRequest] {
        stateLock.lock(); defer { stateLock.unlock() }
        return recordedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let canned: CannedResponse
        Self.stateLock.lock()
        Self.recordedRequests.append(request)
        if Self.cannedResponses.isEmpty {
            Self.stateLock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        canned = Self.cannedResponses.removeFirst()
        Self.stateLock.unlock()

        let work = {
            if let error = canned.error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(
                url: self.request.url!,
                statusCode: canned.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: canned.headers
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: canned.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }

        if canned.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + canned.delay, execute: work)
        } else {
            work()
        }
    }

    override func stopLoading() {}
}

/// Builds a URLSessionTransport whose URLSession routes through StubURLProtocol.
private func makeStubbedTransport(
    retryPolicy: RetryPolicy = .default,
    debugLogging: Bool = false
) -> URLSessionTransport {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: config)
    let clientConfig = ClientConfiguration(
        url: URL(string: "http://test")!,
        apiKey: "k",
        debugLogging: debugLogging,
        retryPolicy: retryPolicy
    )
    return URLSessionTransport(configuration: clientConfig, session: session)
}

@Suite("Transport retry behaviour", .serialized)
struct TransportRetryTests {

    @Test("429 + Retry-After then 200 retries once and succeeds")
    func retryOn429() async throws {
        StubURLProtocol.reset(with: [
            .init(statusCode: 429, headers: ["Retry-After": "0"], body: Data(), delay: 0, error: nil),
            .ok(),
        ])

        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0, jitter: 0, honoursRetryAfter: true)
        let transport = makeStubbedTransport(retryPolicy: policy)

        let (data, response) = try await transport.rawRequest(
            method: .get, path: "/items", body: nil, contentType: nil, query: nil
        )
        #expect(response.statusCode == 200)
        #expect(!data.isEmpty)
        #expect(StubURLProtocol.recorded().count == 2)
    }

    @Test("GET 500 retries on idempotent method")
    func retry500OnGet() async throws {
        StubURLProtocol.reset(with: [
            .init(statusCode: 500, headers: [:], body: Data(), delay: 0, error: nil),
            .ok(),
        ])

        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0, jitter: 0)
        let transport = makeStubbedTransport(retryPolicy: policy)

        let (_, response) = try await transport.rawRequest(
            method: .get, path: "/items", body: nil, contentType: nil, query: nil
        )
        #expect(response.statusCode == 200)
        #expect(StubURLProtocol.recorded().count == 2)
    }

    @Test("POST 500 does NOT retry (non-idempotent)")
    func noRetry500OnPost() async throws {
        StubURLProtocol.reset(with: [
            .init(statusCode: 500, headers: [:], body: Data("boom".utf8), delay: 0, error: nil),
            .ok(),  // should not be consumed
        ])

        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0, jitter: 0)
        let transport = makeStubbedTransport(retryPolicy: policy)

        let (_, response) = try await transport.rawRequest(
            method: .post, path: "/items", body: nil, contentType: "application/json", query: nil
        )
        #expect(response.statusCode == 500)
        #expect(StubURLProtocol.recorded().count == 1)
    }

    @Test("Transient URLError (timedOut) retries for POST")
    func retryTransientURLErrorOnPost() async throws {
        StubURLProtocol.reset(with: [
            .error(.timedOut),
            .ok(status: 201),
        ])

        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0, jitter: 0)
        let transport = makeStubbedTransport(retryPolicy: policy)

        let (_, response) = try await transport.rawRequest(
            method: .post, path: "/items", body: nil, contentType: "application/json", query: nil
        )
        #expect(response.statusCode == 201)
        #expect(StubURLProtocol.recorded().count == 2)
    }

    @Test("Exhausted retries return last 500 response")
    func exhaustedRetriesReturnsLast() async throws {
        StubURLProtocol.reset(with: [
            .init(statusCode: 500, headers: [:], body: Data(), delay: 0, error: nil),
            .init(statusCode: 500, headers: [:], body: Data(), delay: 0, error: nil),
            .init(statusCode: 500, headers: [:], body: Data(), delay: 0, error: nil),
        ])

        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0, jitter: 0)
        let transport = makeStubbedTransport(retryPolicy: policy)

        let (_, response) = try await transport.rawRequest(
            method: .get, path: "/items", body: nil, contentType: nil, query: nil
        )
        #expect(response.statusCode == 500)
        #expect(StubURLProtocol.recorded().count == 3)
    }

    @Test("X-RateLimit headers update the shared state")
    func rateLimitHeadersUpdate() async throws {
        StubURLProtocol.reset(with: [
            .ok(status: 200, body: "{}", headers: ["X-RateLimit-Remaining": "7"]),
        ])

        let policy = RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0, jitter: 0)
        let transport = makeStubbedTransport(retryPolicy: policy)

        _ = try await transport.rawRequest(
            method: .get, path: "/items", body: nil, contentType: nil, query: nil
        )

        let remaining = await transport.rateLimitState.remaining
        #expect(remaining == 7)
    }

    @Test("Task cancellation throws CancellationError")
    func taskCancellationThrows() async throws {
        StubURLProtocol.reset(with: [
            .init(statusCode: 200, headers: [:], body: Data(), delay: 5.0, error: nil),
        ])

        let policy = RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0, jitter: 0)
        let transport = makeStubbedTransport(retryPolicy: policy)

        let task = Task {
            try await transport.rawRequest(
                method: .get, path: "/slow", body: nil, contentType: nil, query: nil
            )
        }

        // Yield briefly so the request is in-flight.
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}
