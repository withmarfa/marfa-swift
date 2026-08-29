import Foundation

/// Transport layer for HTTP communication with the Marfa API.
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

    /// Sends a raw HTTP request with an upload-progress callback.
    ///
    /// `onBytesSent` is invoked one or more times during the request
    /// body's transfer, with the current bytes-sent total and the
    /// expected grand total. Called from `URLSession`'s delegate
    /// queue — implementations must not assume a specific executor.
    ///
    /// The progress callback is optional; passing a no-op closure
    /// preserves the semantics of ``rawRequest(method:path:body:contentType:query:)``.
    func rawUpload(
        method: HTTPMethod,
        path: String,
        body: Data,
        contentType: String?,
        query: [(String, String)]?,
        onBytesSent: @Sendable @escaping (Int64, Int64) -> Void
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
            continuation.finish(throwing: MarfaError(
                code: "not_supported",
                message: "Transport does not support eventStream",
                status: 0
            ))
        }
    }

    /// Default `rawUpload` that routes to ``rawRequest`` and discards
    /// progress. Third-party `Transport` implementations opt in to the
    /// progress-delegate path by overriding; the SDK's bundled
    /// `URLSessionTransport` and test-support `MockTransport` both do.
    func rawUpload(
        method: HTTPMethod,
        path: String,
        body: Data,
        contentType: String?,
        query: [(String, String)]?,
        onBytesSent: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        try await rawRequest(
            method: method, path: path, body: body,
            contentType: contentType, query: query
        )
    }

    /// Sends a multipart/form-data request with a single file field.
    ///
    /// Used by ``ProfileNamespace/uploadAvatar(_:mimeType:)`` and any
    /// other endpoint that requires `multipart/form-data` bodies. The
    /// existing ``BlobsNamespace`` posts raw bytes with the MIME type as
    /// `Content-Type`, so it doesn't go through this helper.
    ///
    /// Builds an RFC 7578 envelope with one part named `fieldName`
    /// carrying `data` under the supplied `filename` and `mimeType`, then
    /// routes through ``rawRequest(method:path:body:contentType:query:)``
    /// so auth, retry, and rate-limit handling all apply.
    ///
    /// `method` carries no default on purpose. It had one, and a defaulted
    /// verb is invisible in the source: a call site that omits it reads as a
    /// route with no method at all. No call site ever omitted it, so nothing
    /// broke — but deleting the argument from the one caller and running
    /// `RouteCoverageTests` reported this working wrapper as unwrapped, and
    /// told the reader to record it as a deliberate omission. Spelling the
    /// verb at every call site costs a line and keeps the route readable from
    /// the text.
    func uploadMultipart(
        method: HTTPMethod,
        path: String,
        fieldName: String,
        filename: String,
        data: Data,
        mimeType: String,
        query: [(String, String)]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let boundary = "marfa.multipart.\(UUID().uuidString)"
        var body = Data()
        let crlf = "\r\n"

        let header = """
        --\(boundary)\(crlf)Content-Disposition: form-data; name="\(fieldName)"; filename="\(filename)"\(crlf)Content-Type: \(mimeType)\(crlf)\(crlf)
        """
        body.append(Data(header.utf8))
        body.append(data)
        body.append(Data("\(crlf)--\(boundary)--\(crlf)".utf8))

        return try await rawRequest(
            method: method,
            path: path,
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            query: query
        )
    }
}
