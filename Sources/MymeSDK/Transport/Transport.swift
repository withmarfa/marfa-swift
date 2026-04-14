import Foundation

/// Transport layer for HTTP communication with the Myme API.
///
/// Implement this protocol to inject mock transports in tests.
public protocol Transport: Sendable {

    /// Sends a JSON request and decodes the response.
    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T

    /// Sends a JSON request that may return a 409 conflict.
    /// Returns `.success` with the decoded response, or `.failure` with conflict data.
    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> ConflictResult<T>

    /// Sends a raw HTTP request and returns the response data and metadata.
    func rawRequest(
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?,
        query: [(String, String)]?
    ) async throws -> (Data, HTTPURLResponse)

    /// Opens a Server-Sent Events stream and yields parsed events.
    ///
    /// Transport owns connection establishment and parsing; reconnect logic
    /// and `Last-Event-ID` cursor persistence are the consumer's
    /// responsibility. When the stream fails, the error is thrown through
    /// the returned `AsyncThrowingStream`.
    func eventStream(
        path: String,
        query: [(String, String)]?,
        lastEventID: String?
    ) -> AsyncThrowingStream<SSEEvent, Error>
}

public extension Transport {
    /// Default `eventStream` that signals unsupported. Concrete transports
    /// (URLSessionTransport, and test-support MockTransport) override.
    func eventStream(
        path: String,
        query: [(String, String)]?,
        lastEventID: String?
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: MymeError(
                code: "not_supported",
                message: "Transport does not support eventStream",
                status: 0
            ))
        }
    }
}
