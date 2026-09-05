import Foundation
import os

/// URLSession-based implementation of the `Transport` protocol.
final class URLSessionTransport: Transport {

    private let baseURL: URL
    private let tokenProvider: any TokenProvider
    private let session: URLSession
    private let streamSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let logger: MarfaLogger
    private let debugLogging: Bool
    private let retryPolicy: RetryPolicy
    let rateLimitState: RateLimitState
    /// Shared by every path that can force a renewal, so they cannot each
    /// keep their own idea of whether the mechanism is standing.
    private let forcedRefreshLatch: ForcedRefreshLatch

    convenience init(configuration: ClientConfiguration) {
        self.init(configuration: configuration, protocolClasses: nil)
    }

    /// Ordinary requests and event streams run on two `URLSession`s, and
    /// that is forced rather than chosen. `timeoutIntervalForResource`
    /// bounds a request's whole life and has no `URLRequest` counterpart, so
    /// a single request cannot opt out of the session's value. An event
    /// stream is a request with no natural end — it is meant to be held for
    /// as long as the client runs — while an ordinary call wants exactly
    /// that bound, so the two cannot share a session. Sharing one is what
    /// made a healthy stream end every two minutes and reconnect, replaying
    /// from its cursor, for no reason the server had given.
    ///
    /// The stream session leaves `timeoutIntervalForResource` at the
    /// URLSession default and relies on `timeoutIntervalForRequest`, which
    /// measures silence rather than elapsed time: the server's heartbeat
    /// resets it on a live stream, and nothing resets it on a dead one.
    ///
    /// `protocolClasses` installs a `URLProtocol` stub; a test harness is the
    /// only caller that passes one. Both configurations are built in here
    /// rather than handed in, because the split depends on the two sessions
    /// holding two distinct configuration objects: a seam that took a
    /// caller's configuration would let one object reach both sessions and
    /// quietly restore the shared-session behavior this exists to remove.
    ///
    /// A session carrying an injected protocol handler is ephemeral, so a
    /// suite's stubbed responses never touch the process's shared URL cache
    /// or cookie jar. The timeouts that distinguish the two sessions are
    /// applied identically either way, so a stubbed test exercises the same
    /// split the shipped client runs.
    init(configuration: ClientConfiguration, protocolClasses: [AnyClass]?) {
        func baseConfiguration() -> URLSessionConfiguration {
            guard let protocolClasses else { return .default }
            let stubbed = URLSessionConfiguration.ephemeral
            stubbed.protocolClasses = protocolClasses
            return stubbed
        }

        let requestConfig = baseConfiguration()
        requestConfig.timeoutIntervalForRequest = configuration.timeoutInterval
        requestConfig.timeoutIntervalForResource = configuration.resourceTimeout

        let streamConfig = baseConfiguration()
        streamConfig.timeoutIntervalForRequest = configuration.streamTimeout

        self.baseURL = configuration.url
        self.tokenProvider = configuration.tokenProvider
        self.session = URLSession(configuration: requestConfig)
        self.streamSession = URLSession(configuration: streamConfig)
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        self.logger = MarfaLogger(category: "transport")
        self.debugLogging = configuration.debugLogging
        self.retryPolicy = configuration.retryPolicy
        self.rateLimitState = RateLimitState()
        self.forcedRefreshLatch = ForcedRefreshLatch()
    }

    /// `URLSession` holds its owner alive until it is invalidated, so a
    /// transport that simply goes out of scope leaks its sessions and their
    /// connection pools for the life of the process. Two sessions now, and
    /// the leak predates the second one. `finishTasksAndInvalidate` rather
    /// than `invalidateAndCancel` so an upload or a stream still in flight
    /// completes instead of being cut off by an unrelated deallocation.
    deinit {
        session.finishTasksAndInvalidate()
        streamSession.finishTasksAndInvalidate()
    }

    // MARK: - Transport Protocol

    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T {
        // **A write reaching this overload still gets a key, minted here.**
        // This is the door a client with no local store uses, and it has no
        // queue behind it — but it does have the retry loop below, which
        // retries `.timedOut` and `.networkConnectionLost` on any method. A
        // timeout does not mean the write did not land; it means this side
        // stopped waiting, and the server may have committed and lost only
        // the response. Unkeyed, that retry is a second create.
        //
        // Minted per call, so the retries of one call share it and two calls
        // never do — a key shared across calls would make the second write a
        // replay of the first and drop it silently, which is worse than the
        // duplicate it would be preventing.
        try await request(
            method: method,
            path: path,
            body: body,
            query: query,
            idempotencyKey: HTTPMethod.isWrite(method) ? UUIDv7.generateString() : nil
        )
    }

    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?,
        idempotencyKey: String?
    ) async throws -> T {
        let bodyData = try encodeBody(body)
        let (data, response) = try await rawRequest(
            method: method, path: path, body: bodyData,
            contentType: body != nil ? "application/json" : nil, query: query,
            idempotencyKey: idempotencyKey
        )

        if response.statusCode == 409 {
            // **The two 409 bodies are mutually exclusive by required key, so
            // neither can swallow the other and the order here is not
            // load-bearing** — swapping these two branches changes no
            // behaviour, which was measured rather than assumed. Two
            // independent guards hold it up and *either one alone is enough*:
            // this branch requires `requested_version`, which the merge body
            // never carries, and requires a `code` that decodes as the
            // single-case enum, which `version_conflict` never does. Relaxing
            // one is survivable; relaxing both is what silently turns every
            // merge conflict into a thinned ancestor, and that is the case
            // `AncestorUnavailableTests` exists to catch. This body means
            // there is no ancestor left to diff against.
            if let thinned = try? decoder.decode(AncestorUnavailableResponse.self, from: data) {
                throw AncestorUnavailableError(
                    current: thinned.current,
                    requestedVersion: thinned.requestedVersion,
                    message: thinned.error.message
                )
            }
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
        query: [(String, String)]?,
        idempotencyKey: String?
    ) async throws -> ConflictResult<T> {
        let bodyData = try encodeBody(body)
        let (data, response) = try await rawRequest(
            method: method, path: path, body: bodyData,
            contentType: body != nil ? "application/json" : nil, query: query,
            idempotencyKey: idempotencyKey
        )

        if response.statusCode == 409 {
            // **The two 409 bodies are mutually exclusive by required key, so
            // neither can swallow the other and the order here is not
            // load-bearing** — swapping these two branches changes no
            // behaviour, which was measured rather than assumed. Two
            // independent guards hold it up and *either one alone is enough*:
            // this branch requires `requested_version`, which the merge body
            // never carries, and requires a `code` that decodes as the
            // single-case enum, which `version_conflict` never does. Relaxing
            // one is survivable; relaxing both is what silently turns every
            // merge conflict into a thinned ancestor, and that is the case
            // `AncestorUnavailableTests` exists to catch. This body means
            // there is no ancestor left to diff against.
            if let thinned = try? decoder.decode(AncestorUnavailableResponse.self, from: data) {
                throw AncestorUnavailableError(
                    current: thinned.current,
                    requestedVersion: thinned.requestedVersion,
                    message: thinned.error.message
                )
            }
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
    ///
    /// Returns the token it applied so a caller that later gets a 401 can
    /// name the exact credential the server refused.
    @discardableResult
    private func applyAuthHeader(to request: inout URLRequest) async throws -> Token {
        let token = try await tokenProvider.currentToken()
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        return token
    }

    /// Send, and on a 401 a renewal could plausibly fix, name the refused
    /// credential to the provider, re-mint the header, and send exactly once
    /// more.
    ///
    /// This exists as one helper because the three transport paths drifted.
    /// `rawRequest` grew the recovery and the other two never got it, so an
    /// attachment upload or a live subscription signed the user out on a 401
    /// the very same client recovered from on any other call. A shared helper
    /// is what makes "symmetric across every path" a property of the code
    /// rather than of whoever edits it next.
    ///
    /// Not used by `rawRequest`, which has a retry loop of its own and folds
    /// the same two rules into it; `TransportForcedRefreshParityTests` pins
    /// the three against each other.
    private func sendWithForcedRefreshOn401<R: Sendable>(
        request: URLRequest,
        sentToken: Token,
        statusCode: @Sendable (R) -> Int?,
        send: (URLRequest) async throws -> R
    ) async throws -> R {
        let first = try await send(request)
        let firstStatus = statusCode(first)
        guard firstStatus == 401, await forcedRefreshLatch.allowsForcedRefresh
        else {
            if let firstStatus {
                await forcedRefreshLatch.record(
                    statusCode: firstStatus, afterForcedRefresh: false
                )
            }
            return first
        }

        await tokenProvider.invalidate(sentToken)
        var retried = request
        try await applyAuthHeader(to: &retried)
        let second = try await send(retried)
        if let secondStatus = statusCode(second) {
            await forcedRefreshLatch.record(
                statusCode: secondStatus, afterForcedRefresh: true
            )
        }
        return second
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
        let sentToken = try await applyAuthHeader(to: &request)
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
            // A 401 here is recoverable exactly as it is on any other call,
            // and this is the attachment path: it backs blob upload and the
            // sync engine, so a refused credential used to end an upload in a
            // sign-out rather than a retry.
            let (data, httpResponse) = try await sendWithForcedRefreshOn401(
                request: request,
                sentToken: sentToken,
                statusCode: { $0.1.statusCode }
            ) { attemptRequest in
                let (data, response) = try await self.session.upload(
                    for: attemptRequest, from: body, delegate: delegate
                )
                guard let httpResponse = response as? HTTPURLResponse else {
                    self.logger.log.error(
                        "http.error request_id=\(requestId, privacy: .public) reason=not_http"
                    )
                    throw NetworkError(URLError(.badServerResponse))
                }
                await self.rateLimitState.update(from: httpResponse.allHeaderFields)
                return (data, httpResponse)
            }
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
        } catch let error as MarfaError {
            // Same clause `rawRequest` carries, and for the same reason: this
            // is most often an ``OAuthError`` from re-minting the header after
            // a 401 found the grant gone. Wrapping it in a NetworkError buries
            // the code callers branch on, so an upload against a dead session
            // reads as a connectivity blip and gets retried instead of signing
            // the user out. The parity suite asserted the recovery and never
            // the error shape, so the gap survived the commit named for it.
            logger.log.error(
                "http.error request_id=\(requestId, privacy: .public) code=\(error.code, privacy: .public)"
            )
            throw error
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
        try await rawRequest(
            method: method, path: path, body: body,
            contentType: contentType, query: query, idempotencyKey: nil
        )
    }

    /// The one place a request is actually built, so the key cannot be
    /// stamped on some paths and forgotten on others.
    func rawRequest(
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?,
        query: [(String, String)]?,
        idempotencyKey: String?
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try buildURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        let sentToken = try await applyAuthHeader(to: &request)

        // Stamp an `X-Request-ID` on every request so the server-side log
        // line and this client-side log line can be correlated when a
        // mutation fails. Preserved across in-request retries — it's one
        // logical call from the app's perspective.
        let requestId = UUIDv7.generateString()
        request.setValue(requestId, forHTTPHeaderField: "X-Request-ID")

        // Stamped on every attempt at one queued write, and the SAME value
        // each time — that sameness is the entire mechanism, and it is why
        // this sits beside `X-Request-ID` rather than reusing it. That one is
        // deliberately the opposite: a fresh value per attempt, so two
        // attempts can be told apart in a log.
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }

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
        // `attempt` counts transient-failure retries and is advanced by hand,
        // because the one 401 recovery must not spend from that budget. A
        // credential correction is a different thing from "the network
        // flaked, try again": it re-sends the same call with a credential the
        // server has not refused, and it is bounded by `didRefreshOn401`
        // rather than by the policy.
        //
        // Under `for attempt in 1...maxAttempts` it did spend one, and with
        // the public `RetryPolicy.none` (`maxAttempts == 1`) there was none to
        // spend: the `continue` left the loop, so the refresh token had been
        // burned, the retry never fired, and the caller got a `NetworkError`
        // for what was an auth failure. Strictly worse than having no recovery
        // at all, and invisible because no test drove `RetryPolicy.none`.
        var attempt = 1
        while attempt <= retryPolicy.maxAttempts {
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

                // 401-refresh-once: report the exact credential the server
                // refused, re-mint the auth header, and retry the same
                // request a single time. Naming the token is what lets the
                // provider tell "this is dead, renew it" apart from "you are
                // behind, a newer one already exists" — the second case is
                // every request that was in flight when the renewal landed,
                // and renewing for each of those is a storm. Subsequent 401s
                // surface as ``UnauthorizedError`` to the caller.
                if httpResponse.statusCode == 401,
                    !didRefreshOn401,
                    await forcedRefreshLatch.allowsForcedRefresh
                {
                    didRefreshOn401 = true
                    await tokenProvider.invalidate(sentToken)
                    try await applyAuthHeader(to: &request)
                    logger.log.info(
                        "http.retry.refresh request_id=\(requestId, privacy: .public) method=\(method.rawValue, privacy: .public) path=\(path, privacy: .public) attempt=\(attempt, privacy: .public)"
                    )
                    // Deliberately not advancing `attempt`: see the loop
                    // header. Not delaying either — backing off before
                    // presenting a corrected credential would slow every
                    // recovery down for no reason.
                    continue
                }

                await forcedRefreshLatch.record(
                    statusCode: httpResponse.statusCode,
                    afterForcedRefresh: didRefreshOn401
                )

                let shouldRetry = attempt < retryPolicy.maxAttempts && retryPolicy.shouldRetry(
                    method: method,
                    statusCode: httpResponse.statusCode,
                    urlError: nil
                )

                if shouldRetry {
                    logger.log.info(
                        "http.retry request_id=\(requestId, privacy: .public) method=\(method.rawValue, privacy: .public) path=\(path, privacy: .public) status=\(httpResponse.statusCode, privacy: .public) attempt=\(attempt, privacy: .public)"
                    )
                    attempt += 1
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
                    attempt += 1
                    continue
                }
                logger.log.error(
                    "http.error request_id=\(requestId, privacy: .public) method=\(method.rawValue, privacy: .public) path=\(path, privacy: .public) url_error=\(error.code.rawValue, privacy: .public)"
                )
                throw NetworkError(error)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MarfaError {
                // Already a fully formed SDK error — most often an
                // ``OAuthError`` from the token provider when re-minting the
                // header after a 401 finds the grant gone. Wrapping it in a
                // NetworkError would bury the OAuth code callers branch on and
                // dress an auth failure up as a connectivity one.
                logger.log.error(
                    "http.error request_id=\(requestId, privacy: .public) method=\(method.rawValue, privacy: .public) path=\(path, privacy: .public) code=\(error.code, privacy: .public)"
                )
                throw error
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
                    let sentToken = try await self.applyAuthHeader(to: &request)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let lastEventID {
                        request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
                    }

                    let sseLogger = MarfaLogger(category: "sse")
                    sseLogger.log.info(
                        "sse.open path=\(path, privacy: .public) last_event_id=\(lastEventID ?? "-", privacy: .public)"
                    )

                    // The 401 recovery applies to opening the stream, not to
                    // bytes already flowing: a stream that dies mid-flight is
                    // the reconnect path's problem, and the caller owns that
                    // decision because it also owns `Last-Event-ID`. Without
                    // this a subscription was the one call in the SDK where a
                    // rotated credential meant a sign-out.
                    let (bytes, httpResponse) =
                        try await self.sendWithForcedRefreshOn401(
                            request: request,
                            sentToken: sentToken,
                            statusCode: { $0.1.statusCode }
                        ) { attemptRequest in
                            let (bytes, response) =
                                try await self.streamSession.bytes(for: attemptRequest)
                            guard let httpResponse = response as? HTTPURLResponse
                            else {
                                throw NetworkError(URLError(.badServerResponse))
                            }
                            return (bytes, httpResponse)
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
