import Testing
import Foundation
@testable import MymeSDK

/// URLProtocol stub that emits a canned SSE body in chunks, with optional
/// delays between chunks to simulate real-time streaming.
final class SSEStubURLProtocol: URLProtocol, @unchecked Sendable {

    struct Config: Sendable {
        var statusCode: Int
        var headers: [String: String]
        var chunks: [Data]
        var interChunkDelay: TimeInterval
    }

    nonisolated(unsafe) static var config: Config = .init(
        statusCode: 200, headers: [:], chunks: [], interChunkDelay: 0
    )
    nonisolated(unsafe) static var lastRequest: URLRequest?
    private static let stateLock = NSLock()

    static func configure(_ newConfig: Config) {
        stateLock.lock(); defer { stateLock.unlock() }
        config = newConfig
        lastRequest = nil
    }

    static func capturedRequest() -> URLRequest? {
        stateLock.lock(); defer { stateLock.unlock() }
        return lastRequest
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let snapshot: Config
        Self.stateLock.lock()
        Self.lastRequest = request
        snapshot = Self.config
        Self.stateLock.unlock()

        let headers = snapshot.headers.merging(["Content-Type": "text/event-stream"]) { a, _ in a }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: snapshot.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let chunks = snapshot.chunks
        let delay = snapshot.interChunkDelay

        // Use DispatchQueue to emit chunks sequentially so URLSession.bytes
        // can iterate them without buffering everything into one delivery.
        let queue = DispatchQueue(label: "sse.stub")
        queue.async {
            for (i, chunk) in chunks.enumerated() {
                if i > 0, delay > 0 {
                    Thread.sleep(forTimeInterval: delay)
                }
                self.client?.urlProtocol(self, didLoad: chunk)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private func makeTransport() -> URLSessionTransport {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SSEStubURLProtocol.self]
    let session = URLSession(configuration: config)
    let clientConfig = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
    return URLSessionTransport(configuration: clientConfig, session: session)
}

@Suite("SSE transport", .serialized)
struct SSETransportTests {

    @Test("Receives events from a streamed body")
    func receivesEvents() async throws {
        let body = "data: one\n\ndata: two\n\ndata: three\n\n"
        SSEStubURLProtocol.configure(.init(
            statusCode: 200,
            headers: [:],
            chunks: [Data(body.utf8)],
            interChunkDelay: 0
        ))
        let transport = makeTransport()

        var received: [SSEEvent] = []
        for try await event in transport.eventStream(path: "/events", query: nil, lastEventID: nil) {
            received.append(event)
        }
        #expect(received.count == 3)
        #expect(received.map(\.data) == ["one", "two", "three"])
    }

    @Test("Sends Last-Event-ID header when provided")
    func sendsLastEventIDHeader() async throws {
        let body = "data: anything\n\n"
        SSEStubURLProtocol.configure(.init(
            statusCode: 200, headers: [:], chunks: [Data(body.utf8)], interChunkDelay: 0
        ))
        let transport = makeTransport()

        for try await _ in transport.eventStream(path: "/events", query: nil, lastEventID: "evt-9") {
            break  // we just care about the request header
        }

        let captured = SSEStubURLProtocol.capturedRequest()
        #expect(captured?.value(forHTTPHeaderField: "Last-Event-ID") == "evt-9")
    }

    @Test("Non-2xx status throws a typed MymeError")
    func non2xxThrows() async throws {
        let body = #"{"error":{"code":"unauthorized","message":"no key"}}"#
        SSEStubURLProtocol.configure(.init(
            statusCode: 401, headers: [:], chunks: [Data(body.utf8)], interChunkDelay: 0
        ))
        let transport = makeTransport()

        var caught: (any Error)?
        do {
            for try await _ in transport.eventStream(path: "/events", query: nil, lastEventID: nil) {}
        } catch {
            caught = error
        }
        #expect(caught is UnauthorizedError)
    }

    @Test("Accept header is text/event-stream")
    func acceptHeaderSet() async throws {
        let body = "data: x\n\n"
        SSEStubURLProtocol.configure(.init(
            statusCode: 200, headers: [:], chunks: [Data(body.utf8)], interChunkDelay: 0
        ))
        let transport = makeTransport()

        for try await _ in transport.eventStream(path: "/events", query: nil, lastEventID: nil) {
            break
        }
        let captured = SSEStubURLProtocol.capturedRequest()
        #expect(captured?.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    }
}
