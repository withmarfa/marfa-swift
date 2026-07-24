import Foundation

/// A source of the bearer token that the SDK transport sends in the
/// `Authorization: Bearer <…>` header on every request.
///
/// Two concrete implementations ship with the SDK:
///
/// - ``StaticTokenProvider`` wraps a never-changing API key string and
///   always returns the same token. Used internally by the existing
///   ``MarfaClient/init(url:apiKey:)`` and
///   ``MarfaClient/fromKeychain(service:account:url:accessGroup:)`` paths.
/// - ``StoredTokenProvider`` holds an OAuth 2.0 access token plus refresh
///   token, persists them via ``SecureStorage``, and transparently
///   refreshes on expiry. Used by ``MarfaAuth``, ``DeviceFlow``, and
///   ``Passkey``.
///
/// Application code can also implement this protocol directly to slot in
/// a custom token source — e.g. a service account whose token is fetched
/// from an external secret manager.
///
/// ## Refresh contract
///
/// ``currentToken()`` may make a network call (to refresh an expired
/// token) but should be cheap on the happy path — the SDK awaits it on
/// every request.
///
/// ``invalidate(_:)`` is invoked by the transport when the server returns
/// `401 Unauthorized`, naming the exact credential that was refused; an
/// implementation holding a cached token should replace it so the next
/// ``currentToken()`` call returns something different.
public protocol TokenProvider: Sendable {
    /// Returns the current valid token, refreshing if necessary.
    ///
    /// Throws the underlying auth failure — an ``OAuthError`` from
    /// ``StoredTokenProvider`` — which propagates to the caller as-is rather
    /// than being reshaped into ``UnauthorizedError``, so the OAuth error
    /// code survives. Apps that need to react to a session ending should
    /// subscribe to ``StoredTokenProvider/authEvents`` instead of inspecting
    /// throws at every call site, since background work (sync, prefetch) has
    /// no call site the user is looking at.
    func currentToken() async throws -> Token

    /// Marks any cached token as stale.
    ///
    /// Default implementation is a no-op for static / non-cacheable
    /// providers. ``StoredTokenProvider`` overrides this to drop the
    /// in-memory copy so the next call re-reads storage.
    func invalidate() async

    /// Reports that the server refused `rejected`, so that the provider can
    /// replace it before the transport retries.
    ///
    /// Naming the failed credential rather than saying "something is wrong"
    /// is what keeps recovery bounded. Requests already in flight when a
    /// replacement lands come back 401 carrying the *old* token; a provider
    /// that renewed on every such report would spend one grant per straggler.
    /// Comparing against what it currently holds lets it renew once and treat
    /// the rest as already handled.
    ///
    /// Returns once the provider has either replaced the credential or
    /// decided it can't. Failure is not thrown here: it surfaces from the
    /// following ``currentToken()``, which is where callers already handle it.
    func invalidate(_ rejected: Token) async
}

extension TokenProvider {
    public func invalidate() async {}

    /// Providers that predate the token-scoped form, or that have no way to
    /// tell one credential from another, fall back to the blanket
    /// ``invalidate()``.
    public func invalidate(_ rejected: Token) async {
        await invalidate()
    }
}

/// A ``TokenProvider`` backed by a single immutable API key.
///
/// The SDK uses this internally to wrap the existing API-key flow so the
/// transport has one auth contract (``TokenProvider``) regardless of which
/// initializer constructed the client. Application code should not
/// instantiate this directly — pass an `apiKey` to ``MarfaClient`` or use
/// ``MarfaClient/fromKeychain(service:account:url:accessGroup:)`` instead.
public struct StaticTokenProvider: TokenProvider {
    private let token: Token

    public init(apiKey: String) {
        self.token = Token(accessToken: apiKey, tokenType: "Bearer")
    }

    public func currentToken() async throws -> Token { token }
}

/// A ``TokenProvider`` that holds an OAuth-issued ``Token`` and refreshes
/// it transparently as it nears expiry.
///
/// Tokens are persisted via the injected ``SecureStorage`` (typically
/// ``KeychainStorage``). On each ``currentToken()`` call the actor:
///
/// 1. Returns the cached token while it still has comfortable life left.
/// 2. Refreshes against ``tokenEndpoint`` shortly *before* expiry, so
///    requests rarely queue behind an exchange.
/// 3. Refreshes on demand when the transport reports a rejected credential,
///    because expiry is only one of the ways a token dies.
/// 4. Fails permanently once the server says the grant is gone, emitting
///    ``AuthEvent/signedOut(reason:)`` on ``authEvents``.
///
/// ## Refresh-token rotation
///
/// The server issues a new refresh token on every exchange and invalidates
/// the previous one; replaying a superseded token reads as theft and revokes
/// the entire grant. Two properties follow, and both are load-bearing:
///
/// - **Refreshes are single-flight.** Actor isolation alone does not give
///   this. The exchange suspends on the network, which releases the actor and
///   lets the next caller observe the same stale token and start a second
///   exchange; the loser then replays a rotated token and kills the session.
///   Concurrent callers are coalesced onto one task instead.
/// - **Only unambiguous failures are retried.** Replaying a token the server
///   may already have rotated is indistinguishable from an attack, so retries
///   are limited to statuses that prove the grant was never reached.
public actor StoredTokenProvider: TokenProvider {
    private let storage: any SecureStorage
    private let storageKey: String
    private let tokenEndpoint: URL
    private let clientId: String
    private let urlSession: URLSession
    private let retryPolicy: RetryPolicy
    private var cached: Token?

    /// How long before actual expiry a token is treated as due for refresh.
    /// Refreshing early means in-flight requests don't all pile onto one
    /// exchange at the instant the token lapses.
    private static let proactiveRefreshWindow: TimeInterval = 60

    /// Statuses safe to replay a refresh token against. Both mean the server
    /// turned the request away before it reached the grant, so the token is
    /// provably unrotated. A timeout or a 5xx is ambiguous — the exchange may
    /// have succeeded with the response lost, and replaying then trips reuse
    /// detection and ends the session, turning a recoverable blip into a
    /// forced sign-out.
    private static let retryableStatuses: Set<Int> = [429, 503]

    /// Set once the server has rejected the grant. While non-nil every
    /// ``currentToken()`` fails immediately with no network call: a revoked
    /// grant cannot be revived by asking again, and asking again in a loop is
    /// how a stale session becomes a request storm.
    private var terminalFailure: OAuthError?

    /// The exchange every concurrent caller awaits.
    private var inflightRefresh: Task<Token, Error>?

    private var continuations: [AsyncStream<AuthEvent>.Continuation] = []

    public init(
        storage: any SecureStorage,
        storageKey: String,
        tokenEndpoint: URL,
        clientId: String,
        urlSession: URLSession = .shared,
        retryPolicy: RetryPolicy = .default
    ) {
        self.storage = storage
        self.storageKey = storageKey
        self.tokenEndpoint = tokenEndpoint
        self.clientId = clientId
        self.urlSession = urlSession
        self.retryPolicy = retryPolicy
    }

    // MARK: - Auth events

    /// Session-lifecycle events. A ``AuthEvent/signedOut(reason:)`` is the
    /// app's cue to present sign-in.
    ///
    /// Deliberate local sign-out through ``clear()`` deliberately does *not*
    /// emit: the app already knows, and echoing it back invites a handler
    /// that signs out in response to signing out. Past events are not
    /// replayed to late subscribers.
    public nonisolated var authEvents: AsyncStream<AuthEvent> {
        AsyncStream<AuthEvent> { continuation in
            Task { await self.subscribe(continuation) }
        }
    }

    private func subscribe(_ continuation: AsyncStream<AuthEvent>.Continuation) {
        continuations.append(continuation)
    }

    private func emit(_ event: AuthEvent) {
        continuations.removeAll { continuation in
            switch continuation.yield(event) {
            case .terminated: return true
            default: return false
            }
        }
    }

    // MARK: - Storage

    /// Stores `token` in ``storage`` and in memory. Called by auth flows
    /// after an initial grant, and after every rotation.
    ///
    /// Storage is written *before* the in-memory cache: if the write fails,
    /// memory must not be left holding a token that disk doesn't have, or the
    /// next launch reloads the superseded one and trips reuse detection. A
    /// successful store also clears any terminal failure, since a fresh grant
    /// revives the provider.
    public func store(_ token: Token) async throws {
        let data = try JSONEncoder.iso8601.encode(token)
        guard let json = String(data: data, encoding: .utf8) else {
            throw OAuthError(rawCode: "encoding_failed", message: "could not encode token", status: 500)
        }
        try await storage.set(json, for: storageKey)
        cached = token
        terminalFailure = nil
    }

    /// Removes the stored token. Used by sign-out flows.
    public func clear() async throws {
        cached = nil
        terminalFailure = nil
        inflightRefresh?.cancel()
        inflightRefresh = nil
        try await storage.delete(for: storageKey)
    }

    public func currentToken() async throws -> Token {
        if let terminalFailure { throw terminalFailure }
        if let token = try await loadCached(), !needsRefresh(token) {
            return token
        }
        return try await refresh()
    }

    /// Drops the in-memory copy so the next call re-reads storage.
    ///
    /// This alone cannot recover a rejected credential: storage still holds
    /// the same token, and one that has not reached its expiry is handed
    /// straight back. Callers that know which credential was refused should
    /// use ``invalidate(_:)``, which can exchange it.
    public func invalidate() async {
        cached = nil
    }

    /// Exchanges `rejected` for a new token, if it is still the credential
    /// this provider hands out.
    ///
    /// Expiry is only one way an access token dies. Revocation, a signing-key
    /// rotation, or a request that waited long enough to outlive the
    /// credential it was stamped with all produce a 401 while the clock still
    /// reads valid — which the proactive window cannot see. Without an
    /// exchange here the retry re-reads the same token from storage and sends
    /// it again, ending a session that a live refresh token could have saved.
    ///
    /// Recovery driven by request traffic is the shape that becomes a storm,
    /// so it is bounded three ways: the exchange is single-flighted; a report
    /// naming an already-superseded credential does nothing, because a
    /// replacement already exists; and a grant the server has rejected latches,
    /// so every later report returns without touching the network.
    public func invalidate(_ rejected: Token) async {
        guard terminalFailure == nil else { return }
        guard let current = try? await loadCached(),
              current.accessToken == rejected.accessToken
        else { return }
        // A failed exchange deliberately leaves the rejected token in place.
        // The caller's retry then draws the same 401 and surfaces the auth
        // error it already handles, rather than a second error shape from here.
        _ = try? await refresh()
    }

    /// True once the token is within ``proactiveRefreshWindow`` of expiry, or
    /// already past it. Tokens with no expiry never need refreshing.
    private func needsRefresh(_ token: Token) -> Bool {
        guard let expiry = token.expiresAt else { return false }
        return expiry.timeIntervalSinceNow <= Self.proactiveRefreshWindow
    }

    /// Loads the cached token, falling back to ``storage`` when the
    /// in-memory cache is empty.
    private func loadCached() async throws -> Token? {
        if let token = cached { return token }
        guard let json = try await storage.get(for: storageKey),
              let data = json.data(using: .utf8) else {
            return nil
        }
        let token = try JSONDecoder.iso8601.decode(Token.self, from: data)
        cached = token
        return token
    }

    // MARK: - Refresh

    /// Coalesces concurrent callers onto a single exchange. Anyone arriving
    /// while a refresh is in flight awaits that same task rather than
    /// starting a second one against the same about-to-be-rotated token.
    private func refresh() async throws -> Token {
        if let inflight = inflightRefresh {
            return try await inflight.value
        }
        let task = Task<Token, Error> { try await self.performRefresh() }
        inflightRefresh = task
        defer { inflightRefresh = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> Token {
        // The latch can be set between this task being created and its first
        // line running, since every caller takes its own turn on the actor.
        // Re-checking here stops a caller queued behind a just-failed exchange
        // from replaying a refresh token the server has already rotated.
        if let terminalFailure { throw terminalFailure }

        guard let refreshToken = try await loadCached()?.refreshToken else {
            let error = OAuthError(
                rawCode: "invalid_grant",
                message: "no refresh token available — re-authenticate",
                status: 401
            )
            await enterTerminalState(reason: .noRefreshToken, error: error)
            throw error
        }

        var attempt = 1
        while true {
            let (data, http) = try await exchange(refreshToken: refreshToken)

            if (200..<300).contains(http.statusCode) {
                let fresh = try JSONDecoder.iso8601.decode(Token.self, from: data)
                // Rotation normally returns a new refresh token. If a response
                // omits one, keep the token we just spent so the session
                // retains a way to refresh at all.
                let token = fresh.refreshToken == nil
                    ? Token(
                        accessToken: fresh.accessToken,
                        tokenType: fresh.tokenType,
                        refreshToken: refreshToken,
                        idToken: fresh.idToken,
                        expiresAt: fresh.expiresAt,
                        scopes: fresh.scopes
                    )
                    : fresh
                try await store(token)
                return token
            }

            let error = try parseOAuthError(data: data, status: http.statusCode)

            if let reason = Self.terminalReason(for: error, status: http.statusCode) {
                await enterTerminalState(reason: reason, error: error)
                throw error
            }

            guard Self.retryableStatuses.contains(http.statusCode),
                  attempt < retryPolicy.maxAttempts
            else { throw error }

            let pause = delay(afterAttempt: attempt, headers: http.allHeaderFields)
            try await Task.sleep(for: .seconds(pause))
            attempt += 1
        }
    }

    private func exchange(refreshToken: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formURLEncode([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ]).data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError(rawCode: "invalid_response", message: "no HTTP response", status: 500)
        }
        return (data, http)
    }

    /// Latches the failure, discards the tokens, and tells subscribers to
    /// send the user back through sign-in.
    private func enterTerminalState(reason: SignOutReason, error: OAuthError) async {
        terminalFailure = error
        cached = nil
        try? await storage.delete(for: storageKey)
        emit(.signedOut(reason: reason))
    }

    /// Classifies a failed exchange. A terminal result means the grant is
    /// gone and only a fresh sign-in recovers it; anything else is worth
    /// surfacing but leaves the session intact.
    private static func terminalReason(for error: OAuthError, status: Int) -> SignOutReason? {
        switch error.oauthCode {
        case .tokenReuseDetected: return .reuseDetected
        case .invalidGrant: return .refreshTokenRejected
        default: break
        }
        // A 400 or 401 the server didn't tag with a recognized OAuth code
        // still means the credential was refused. Asking again cannot change
        // that answer.
        return (status == 400 || status == 401) ? .refreshTokenRejected : nil
    }

    /// Backoff before the next attempt, honoring `Retry-After` when the
    /// server sent one — it knows when its window resets better than we do.
    private func delay(afterAttempt attempt: Int, headers: [AnyHashable: Any]) -> TimeInterval {
        let computed = retryPolicy.delay(forAttempt: attempt + 1)
        guard retryPolicy.honorsRetryAfter,
              let retryAfter = Self.retryAfterSeconds(headers)
        else { return computed }
        return max(computed, retryAfter)
    }

    private static func retryAfterSeconds(_ headers: [AnyHashable: Any]) -> TimeInterval? {
        for (key, value) in headers {
            guard let name = key as? String,
                  name.caseInsensitiveCompare("Retry-After") == .orderedSame
            else { continue }
            if let text = value as? String { return TimeInterval(text) }
            if let number = value as? NSNumber { return number.doubleValue }
        }
        return nil
    }
}

/// Form-encodes a `[String: String]` per `application/x-www-form-urlencoded`.
internal func formURLEncode(_ fields: [String: String]) -> String {
    fields
        .map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: .urlFormAllowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: .urlFormAllowed) ?? value
            return "\(k)=\(v)"
        }
        .joined(separator: "&")
}

private extension CharacterSet {
    /// `application/x-www-form-urlencoded` allowed character set per the
    /// HTML5 form-encoding spec.
    static let urlFormAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+/?")
        return set
    }()
}

/// Parses an RFC 6749 §5.2 OAuth error envelope into ``OAuthError``.
internal func parseOAuthError(data: Data, status: Int) throws -> OAuthError {
    struct Envelope: Decodable {
        let error: String
        let errorDescription: String?
        let errorUri: String?
        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
            case errorUri = "error_uri"
        }
    }
    if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
        return OAuthError(
            rawCode: envelope.error,
            message: envelope.errorDescription ?? envelope.error,
            status: status
        )
    }
    let message = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
    return OAuthError(rawCode: "http_error", message: message, status: status)
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
