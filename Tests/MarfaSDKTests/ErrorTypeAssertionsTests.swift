import Testing
import Foundation
@testable import MarfaSDK

/// Per-suite URLProtocol stub — see `Transport401RefreshTests` for the
/// rationale on scoped subclasses.
final class ErrorAssertionsStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var nextResponse: (Int, Data)?
    nonisolated(unsafe) static var nextURLError: URLError?
    private static let lock = NSLock()

    static func setHTTP(status: Int, body: Data = Data()) {
        lock.lock(); defer { lock.unlock() }
        nextResponse = (status, body)
        nextURLError = nil
    }

    static func setURLError(_ error: URLError) {
        lock.lock(); defer { lock.unlock() }
        nextResponse = nil
        nextURLError = error
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let response = Self.nextResponse
        let urlError = Self.nextURLError
        Self.lock.unlock()

        if let urlError {
            client?.urlProtocol(self, didFailWithError: urlError)
            return
        }
        guard let (status, body) = response else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeStubbedTransport() -> URLSessionTransport {
    let urlConfig = URLSessionConfiguration.ephemeral
    urlConfig.protocolClasses = [ErrorAssertionsStubURLProtocol.self]
    let session = URLSession(configuration: urlConfig)
    let config = ClientConfiguration(
        url: URL(string: "http://test")!,
        apiKey: "k",
        retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0, jitter: 0)
    )
    return URLSessionTransport(configuration: config, session: session)
}

@Suite("Typed error projection", .serialized)
struct ErrorTypeAssertionsTests {

    @Test("403 response parses as ForbiddenError with server message")
    func forbiddenError() async throws {
        let body = #"""
        {"error":{"code":"forbidden","message":"this command requires a platform-admin key"}}
        """#
        ErrorAssertionsStubURLProtocol.setHTTP(status: 403, body: Data(body.utf8))
        let transport = makeStubbedTransport()

        do {
            _ = try await transport.request(
                method: .get, path: "/admin/spaces", body: nil, query: nil
            ) as EmptyResponse
            Issue.record("expected ForbiddenError")
        } catch let error as ForbiddenError {
            #expect(error.status == 403)
            #expect(error.message.contains("platform-admin"))
        }
    }

    @Test("403 with no JSON body still parses as ForbiddenError")
    func forbiddenWithoutJSON() async throws {
        ErrorAssertionsStubURLProtocol.setHTTP(status: 403, body: Data())
        let transport = makeStubbedTransport()

        do {
            _ = try await transport.request(
                method: .get, path: "/admin/spaces", body: nil, query: nil
            ) as EmptyResponse
            Issue.record("expected ForbiddenError")
        } catch is ForbiddenError {
            // expected
        }
    }

    @Test("URLError(.cancelled) translates to CancellationError")
    func urlErrorCancelledBecomesCancellation() async throws {
        ErrorAssertionsStubURLProtocol.setURLError(URLError(.cancelled))
        let transport = makeStubbedTransport()

        do {
            _ = try await transport.request(
                method: .get, path: "/items", body: nil, query: nil
            ) as EmptyResponse
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // expected — the transport unifies URLError(.cancelled) and
            // Task.checkCancellation into a single CancellationError so
            // callers always see Swift's structured cancellation type.
        }
    }

    @Test("404 response parses as NotFoundError")
    func notFoundError() async throws {
        let body = #"""
        {"error":{"code":"not_found","message":"item not found"}}
        """#
        ErrorAssertionsStubURLProtocol.setHTTP(status: 404, body: Data(body.utf8))
        let transport = makeStubbedTransport()

        do {
            _ = try await transport.request(
                method: .get, path: "/items/missing", body: nil, query: nil
            ) as EmptyResponse
            Issue.record("expected NotFoundError")
        } catch let error as NotFoundError {
            #expect(error.status == 404)
        }
    }
}
