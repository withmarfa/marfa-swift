import Foundation
import os

/// URLSession-based implementation of the `Transport` protocol.
final class URLSessionTransport: Transport {

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let logger: MymeLogger
    private let debugLogging: Bool
    private let retryPolicy: RetryPolicy
    let rateLimitState: RateLimitState

    convenience init(configuration: ClientConfiguration) {
        let urlConfig = URLSessionConfiguration.default
        urlConfig.timeoutIntervalForRequest = configuration.timeoutInterval
        urlConfig.timeoutIntervalForResource = configuration.resourceTimeout
        self.init(configuration: configuration, session: URLSession(configuration: urlConfig))
    }

    /// Internal init for test harnesses — injects a pre-built URLSession
    /// so tests can route through a `URLProtocol` stub.
    init(configuration: ClientConfiguration, session: URLSession) {
        self.baseURL = configuration.url
        self.apiKey = configuration.apiKey
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        self.logger = MymeLogger(category: "transport")
        self.debugLogging = configuration.debugLogging
        self.retryPolicy = configuration.retryPolicy
        self.rateLimitState = RateLimitState()
    }

    // MARK: - Transport Protocol

    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T {
        let bodyData = try encodeBody(body)
        let (data, response) = try await rawRequest(
            method: method, path: path, body: bodyData,
            contentType: body != nil ? "application/json" : nil, query: query
        )

        if response.statusCode == 409 {
            if let conflict = try? decoder.decode(ConflictResponse.self, from: data) {
                throw ConflictError(
                    current: conflict.current,
                    ancestor: conflict.ancestor,
                    conflictingFields: conflict.conflictingFields,
                    clientPatch: [:]
                )
            }
            logger.log.error("409 body failed to decode as ConflictResponse; falling back to generic error")
            throw parseMymeError(data: data, statusCode: 409, decoder: decoder)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw parseMymeError(data: data, statusCode: response.statusCode, decoder: decoder)
        }

        if response.statusCode == 204 || data.isEmpty {
            // Attempt to decode an empty/void response — works for types like EmptyResponse
            if let result = EmptyResponse() as? T {
                return result
            }
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ResponseDecodingError(error)
        }
    }

    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> ConflictResult<T> {
        let bodyData = try encodeBody(body)
        let (data, response) = try await rawRequest(
            method: method, path: path, body: bodyData,
            contentType: body != nil ? "application/json" : nil, query: query
        )

        if response.statusCode == 409 {
            if let conflict = try? decoder.decode(ConflictResponse.self, from: data) {
                return .conflict(conflict)
            }
            logger.log.error("409 body failed to decode as ConflictResponse; falling back to generic error")
            throw parseMymeError(data: data, statusCode: 409, decoder: decoder)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw parseMymeError(data: data, statusCode: response.statusCode, decoder: decoder)
        }

        do {
            let result = try decoder.decode(T.self, from: data)
            return .success(result)
        } catch {
            throw ResponseDecodingError(error)
        }
    }

    func rawRequest(
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?,
        query: [(String, String)]?
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try buildURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let body {
            request.httpBody = body
        }

        let signpostID = logger.signposter.makeSignpostID()
        let interval = logger.signposter.beginInterval(
            "HTTP request",
            id: signpostID,
            "\(method.rawValue) \(path)"
        )
        defer { logger.signposter.endInterval("HTTP request", interval) }

        logger.log.info("→ \(method.rawValue, privacy: .public) \(path, privacy: .public)")
        if debugLogging, let body {
            logger.log.debug(
                "request body: \(String(data: body, encoding: .utf8) ?? "<binary>", privacy: .private)"
            )
        }

        var lastError: Error?
        for attempt in 1...retryPolicy.maxAttempts {
            try Task.checkCancellation()

            if attempt > 1 {
                let delay = retryPolicy.delay(forAttempt: attempt)
                let serverDelay = await currentRetryAfterOverride()
                let effective = retryPolicy.honoursRetryAfter
                    ? max(delay, serverDelay ?? 0)
                    : delay
                if effective > 0 {
                    try await Task.sleep(for: .seconds(effective))
                }
                logger.log.debug(
                    "retry attempt \(attempt, privacy: .public)/\(self.retryPolicy.maxAttempts, privacy: .public) after \(effective, privacy: .public)s"
                )
            }

            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    logger.log.error("✗ \(method.rawValue, privacy: .public) \(path, privacy: .public) not-http")
                    throw NetworkError(URLError(.badServerResponse))
                }

                await rateLimitState.update(from: httpResponse.allHeaderFields)

                let shouldRetry = attempt < retryPolicy.maxAttempts && retryPolicy.shouldRetry(
                    method: method,
                    statusCode: httpResponse.statusCode,
                    urlError: nil
                )

                if shouldRetry {
                    logger.log.info(
                        "↻ \(method.rawValue, privacy: .public) \(path, privacy: .public) \(httpResponse.statusCode, privacy: .public) — will retry"
                    )
                    continue
                }

                logger.log.info(
                    "← \(method.rawValue, privacy: .public) \(path, privacy: .public) \(httpResponse.statusCode, privacy: .public)"
                )
                if debugLogging, !data.isEmpty {
                    logger.log.debug(
                        "response body: \(String(data: data, encoding: .utf8) ?? "<binary>", privacy: .private)"
                    )
                }
                return (data, httpResponse)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError {
                lastError = error
                let shouldRetry = attempt < retryPolicy.maxAttempts && retryPolicy.shouldRetry(
                    method: method,
                    statusCode: nil,
                    urlError: error
                )
                if shouldRetry {
                    logger.log.info(
                        "↻ \(method.rawValue, privacy: .public) \(path, privacy: .public) \(error.code.rawValue, privacy: .public) — will retry"
                    )
                    continue
                }
                logger.log.error(
                    "✗ \(method.rawValue, privacy: .public) \(path, privacy: .public) \(error.code.rawValue, privacy: .public)"
                )
                throw NetworkError(error)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.log.error(
                    "✗ \(method.rawValue, privacy: .public) \(path, privacy: .public) \(String(describing: error), privacy: .public)"
                )
                throw NetworkError(error)
            }
        }

        throw NetworkError(lastError ?? URLError(.unknown))
    }

    /// If the most recent `Retry-After` is present, return it as a delay
    /// override; otherwise `nil`.
    private func currentRetryAfterOverride() async -> TimeInterval? {
        await rateLimitState.lastRetryAfter
    }

    // MARK: - SSE

    func eventStream(
        path: String,
        query: [(String, String)]?,
        lastEventID: String?
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try buildURL(path: path, query: query)
                    var request = URLRequest(url: url)
                    request.httpMethod = HTTPMethod.get.rawValue
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let lastEventID {
                        request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
                    }

                    let sseLogger = MymeLogger(category: "sse")
                    sseLogger.log.info("→ SSE \(path, privacy: .public)")

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw NetworkError(URLError(.badServerResponse))
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        // Drain the bytes to assemble the error body.
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw parseMymeError(data: data, statusCode: httpResponse.statusCode)
                    }

                    var parser = SSEParser()
                    var lineBuffer = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if byte == 0x0A {  // \n — line terminator
                            let raw = String(data: lineBuffer, encoding: .utf8) ?? ""
                            // Strip trailing \r to handle CRLF line endings.
                            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
                            if let event = parser.consume(line: line) {
                                continuation.yield(event)
                            }
                            lineBuffer.removeAll(keepingCapacity: true)
                        } else {
                            lineBuffer.append(byte)
                        }
                    }
                    // End of stream: if any bytes remain, treat as a final line;
                    // then flush with a blank line to dispatch any pending block.
                    if !lineBuffer.isEmpty {
                        let raw = String(data: lineBuffer, encoding: .utf8) ?? ""
                        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
                        if let event = parser.consume(line: line) {
                            continuation.yield(event)
                        }
                    }
                    if let final = parser.consume(line: "") {
                        continuation.yield(final)
                    }
                    sseLogger.log.info("← SSE \(path, privacy: .public) closed")
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Private

    private func encodeBody(_ body: (any Encodable & Sendable)?) throws -> Data? {
        guard let body else { return nil }
        do {
            return try encoder.encode(body)
        } catch {
            throw MymeError(code: "encoding_error", message: "Failed to encode request body: \(error.localizedDescription)", status: 0)
        }
    }

    private func buildURL(path: String, query: [(String, String)]?) throws -> URL {
        let fullPath = baseURL.absoluteString.hasSuffix("/")
            ? baseURL.absoluteString.dropLast() + path
            : baseURL.absoluteString + path

        guard var components = URLComponents(string: String(fullPath)) else {
            throw NetworkError(URLError(.badURL))
        }

        if let query, !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }

        guard let url = components.url else {
            throw NetworkError(URLError(.badURL))
        }

        return url
    }

}

// MARK: - Empty Response

/// Placeholder for endpoints that return no meaningful body (DELETE, etc.).
struct EmptyResponse: Codable, Sendable {}

/// AnyEncodable wrapper for encoding arbitrary Encodable values.
struct AnyEncodable: Encodable, @unchecked Sendable {
    private let _encode: (Encoder) throws -> Void

    init(_ value: any Encodable & Sendable) {
        _encode = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
