import Foundation
import os

/// URLSession-based implementation of the `Transport` protocol.
final class URLSessionTransport: Transport {

    private let baseURL: URL
    private let tokenProvider: any TokenProvider
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let logger: MarfaLogger
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
        self.tokenProvider = configuration.tokenProvider
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        self.logger = MarfaLogger(category: "transport")
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
            logger.log.error("http.conflict.decode_failed path=\(path, privacy: .public) reason=conflict_body_not_decodable")
            throw parseMarfaError(data: data, statusCode: 409, decoder: decoder)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw parseMarfaError(data: data, statusCode: response.statusCode, decoder: decoder)
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
            logger.log.error("http.conflict.decode_failed path=\(path, privacy: .public) reason=conflict_body_not_decodable")
            throw parseMarfaError(data: data, statusCode: 409, decoder: decoder)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw parseMarfaError(data: data, statusCode: response.statusCode, decoder: decoder)
        }

        do {
            let result = try decoder.decode(T.self, from: data)
            return .success(result)
        } catch {
            throw ResponseDecodingError(error)
        }
    }

    /// Per-task progress delegate used by ``rawUpload``. Forwards
    /// `didSendBodyData` to the caller-supplied closure. One instance
    /// per call — no shared state, no global session delegate.
    private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let onBytesSent: @Sendable (Int64, Int64) -> Void

        init(onBytesSent: @escaping @Sendable (Int64, Int64) -> Void) {
            self.onBytesSent = onBytesSent
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didSendBodyData bytesSent: Int64,
            totalBytesSent: Int64,
            totalBytesExpectedToSend: Int64
        ) {
            onBytesSent(totalBytesSent, totalBytesExpectedToSend)
        }
    }

    /// Applies the current bearer token to `request` by awaiting
    /// ``tokenProvider``. Used for the three header-setting paths:
    /// ``rawRequest``, ``rawUpload``, and the SSE stream init.
    private func applyAuthHeader(to request: inout URLRequest) async throws {
        let token = try await tokenProvider.currentToken()
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
    }

    func rawUpload(
        method: HTTPMethod,
        path: String,
        body: Data,
        contentType: String?,
        query: [(String, String)]?,
        onBytesSent: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try buildURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        try await applyAuthHeader(to: &request)
        let requestId = UUIDv7.generateString()
        request.setValue(requestId, forHTTPHeaderField: "X-Request-ID")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let signpostID = logger.signposter.makeSignpostID()
        let interval = logger.signposter.beginInterval(
            "HTTP upload",
            id: signpostID,
            "\(method.rawValue) \(path)"
        )
        defer { logger.signposter.endInterval("HTTP upload", interval) }

        logger.log.info(
            "http.upload method=\(method.rawValue, privacy: .public) path=\(path, privacy: .public) request_id=\(requestId, privacy: .public) bytes=\(body.count, privacy: .public)"
        )

        let delegate = UploadProgressDelegate(onBytesSent: onBytesSent)

        do {
            let (data, response) = try await session.upload(
                for: request, from: body, delegate: delegate
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.log.error(
                    "http.error request_id=\(requestId, privacy: .public) reason=not_http"
                )
                throw NetworkError(URLError(.badServerResponse))
            }
            await rateLimitState.update(from: httpResponse.allHeaderFields)
            logger.log.info(
                "http.upload.response request_id=\(requestId, privacy: .public) status=\(httpResponse.statusCode, privacy: .public)"
            )
            return (data, httpResponse)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            logger.log.error(
                "http.error request_id=\(requestId, privacy: .public) url_error=\(error.code.rawValue, privacy: .public)"
            )
            throw NetworkError(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.log.error(
                "http.error request_id=\(requestId, privacy: .public) reason=\(String(describing: error), privacy: .public)"
            )
            throw NetworkError(error)
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
        try await applyAuthHeader(to: &request)

        // Stamp an `X-Request-ID` on every request so the server-side log
        // line and this client-side log line can be correlated when a
        // mutation fails. Preserved across in-request retries — it's one
        // logical call from the app's perspective.
        let requestId = UUIDv7.generateString()
        request.setValue(requestId, forHTTPHeaderField: "X-Request-ID")

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

        logger.log.info(
            "http.request method=\(method.rawValue, privacy: .public) path=\(path, privacy: .public) request_id=\(requestId, privacy: .public)"
        )
        if debugLogging, let body {
            logger.log.debug(
                "http.request.body request_id=\(requestId, privacy: .public) body=\(String(data: body, encoding: .utf8) ?? "<binary>", privacy: .private)"
            )
        }

        var lastError: Error?
        var didRefreshOn401 = false
        for attempt in 1...retryPolicy.maxAttempts {
            try Task.checkCancellation()

            if attempt > 1 {
                let delay = retryPolicy.delay(forAttempt: attempt)
                let serverDelay = await currentRetryAfterOverride()
                let effective = retryPolicy.honorsRetryAfter
                    ? max(delay, serverDelay ?? 0)
                    : delay
                if effective > 0 {
                    try await Task.sleep(for: .seconds(effective))
                }
                logger.log.debug(
                    "http.retry.delay request_id=\(requestId, privacy: .public) attempt=\(attempt, privacy: .public) max=\(self.retryPolicy.maxAttempts, privacy: .public) delay_s=\(effective, privacy: .public)"
                )
            }

            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    logger.log.error(
                        "http.error request_id=\(requestId, privacy: .public) method=\(method.rawValue, privacy: .public) path=\(path, privacy: .public) reason=not_http"
                    )
                    throw NetworkError(URLError(.badServerResponse))
                }

                await rateLimitState.update(from: httpResponse.allHeaderFields)

                // 401-refresh-once: if the credential turned out stale,
                // invalidate the cached token, re-mint the auth header,
                // and retry the same request a single time. Subsequent
                // 401s surface as ``UnauthorizedError`` to the caller.
                if httpResponse.statusCode == 401 && !didRefreshOn401 {
                    didRefreshOn401 = true
                    await tokenProvider.invalidate()
                    try await applyAuthHeader(to: &request)
                    logger.log.info(
                        "http.retry.refresh request_id=\(requestId, privacy: .public) method=\(method.rawValue, privacy: .public) path=\(path, privacy: .public) attempt=\(attempt, privacy: .public)"
                    )
                    continue
                }

                let shouldRetry = attempt < retryPolicy.maxAttempts && retryPolicy.shouldRetry(
                    method: method,
                    statusCode: httpResponse.statusCode,
                    urlError: nil
                )

                if shouldRetry {
                    logger.log.info(
                        "http.retry request_id=\(requestId, privacy: .public) method=\(method.rawValue, privacy: .public) path=\(path, privacy: .public) status=\(httpResponse.statusCode, privacy: .public) attempt=\(attempt, privacy: .public)"
                    )
                    continue
                }

                logger.log.info(
                    "http.response request_id=\(requestId, privacy: .public) method=\(method.rawValue, privacy: .public) path=\(path, privacy: .public) status=\(httpResponse.statusCode, privacy: .public)"
                )
                if debugLogging, !data.isEmpty {
                    logger.log.debug(
                        "http.response.body request_id=\(requestId, privacy: .public) body=\(String(data: data, encoding: .utf8) ?? "<binary>", privacy: .private)"
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
                        "http.retry request_id=\(requestId, privacy: .public) method=\(method.rawValue, privacy: .public) path=\(path, privacy: .public) url_error=\(error.code.rawValue, privacy: .public) attempt=\(attempt, privacy: .public)"
                    )
                    continue
                }
                logger.log.error(
                    "http.error request_id=\(requestId, privacy: .public) method=\(method.rawValue, privacy: .public) path=\(path, privacy: .public) url_error=\(error.code.rawValue, privacy: .public)"
                )
                throw NetworkError(error)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.log.error(
                    "http.error request_id=\(requestId, privacy: .public) method=\(method.rawValue, privacy: .public) path=\(path, privacy: .public) reason=\(String(describing: error), privacy: .public)"
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
                    try await self.applyAuthHeader(to: &request)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let lastEventID {
                        request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
                    }

                    let sseLogger = MarfaLogger(category: "sse")
                    sseLogger.log.info(
                        "sse.open path=\(path, privacy: .public) last_event_id=\(lastEventID ?? "-", privacy: .public)"
                    )

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw NetworkError(URLError(.badServerResponse))
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        // Drain the bytes to assemble the error body.
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw parseMarfaError(data: data, statusCode: httpResponse.statusCode)
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
                    sseLogger.log.info("sse.close path=\(path, privacy: .public)")
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
            throw MarfaError(code: "encoding_error", message: "Failed to encode request body: \(error.localizedDescription)", status: 0)
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
