import Foundation

/// A source of the bearer token that the SDK transport sends in the
/// `Authorization: Bearer <…>` header on every request.
///
/// Two concrete implementations ship with the SDK:
///
/// - ``StaticTokenProvider`` wraps a never-changing API key string and
///   always returns the same token. Used internally by the existing
///   ``MymeClient/init(url:apiKey:)`` and
///   ``MymeClient/fromKeychain(service:account:url:accessGroup:)`` paths.
/// - ``StoredTokenProvider`` holds an OAuth 2.0 access token plus refresh
///   token, persists them via ``SecureStorage``, and transparently
///   refreshes on expiry. Used by ``MymeAuth``, ``DeviceFlow``, and
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
/// ``invalidate()`` is invoked by the transport when the server returns
/// `401 Unauthorized`; an implementation that caches a token in memory
/// should mark it stale so the next ``currentToken()`` call performs a
/// fresh fetch.
public protocol TokenProvider: Sendable {
    /// Returns the current valid token, refreshing if necessary.
    ///
    /// Throws when the underlying credential is no longer recoverable —
    /// the caller (typically the SDK transport) translates this into
    /// ``UnauthorizedError`` so application code can surface a sign-in
    /// prompt.
    func currentToken() async throws -> Token

    /// Marks any cached token as stale.
    ///
    /// Default implementation is a no-op for static / non-cacheable
    /// providers. ``StoredTokenProvider`` overrides this to drop the
    /// in-memory cache and force a refresh on the next call.
    func invalidate() async
}

extension TokenProvider {
    public func invalidate() async {}
}

/// A ``TokenProvider`` backed by a single immutable API key.
///
/// The SDK uses this internally to wrap the existing API-key flow so the
/// transport has one auth contract (``TokenProvider``) regardless of which
/// initializer constructed the client. Application code should not
/// instantiate this directly — pass an `apiKey` to ``MymeClient`` or use
/// ``MymeClient/fromKeychain(service:account:url:accessGroup:)`` instead.
public struct StaticTokenProvider: TokenProvider {
    private let token: Token

    public init(apiKey: String) {
        self.token = Token(accessToken: apiKey, tokenType: "Bearer")
    }

    public func currentToken() async throws -> Token { token }
}

/// A ``TokenProvider`` that holds an OAuth-issued ``Token`` and refreshes
/// it transparently when it expires.
///
/// Tokens are persisted via the injected ``SecureStorage`` (typically
/// ``KeychainStorage``). On each ``currentToken()`` call the actor:
///
/// 1. Returns the in-memory cached token when fresh.
/// 2. Attempts a refresh against ``tokenEndpoint`` when the cached token
///    is expired and a refresh token is available.
/// 3. Throws ``OAuthError`` if no refresh path remains — the caller must
///    re-run a sign-in flow.
///
/// Concurrent callers funnel through actor isolation, so a single refresh
/// covers any number of in-flight requests waiting on the same expired
/// token.
public actor StoredTokenProvider: TokenProvider {
    private let storage: any SecureStorage
    private let storageKey: String
    private let tokenEndpoint: URL
    private let clientId: String
    private let urlSession: URLSession
    private var cached: Token?

    public init(
        storage: any SecureStorage,
        storageKey: String,
        tokenEndpoint: URL,
        clientId: String,
        urlSession: URLSession = .shared
    ) {
        self.storage = storage
        self.storageKey = storageKey
        self.tokenEndpoint = tokenEndpoint
        self.clientId = clientId
        self.urlSession = urlSession
    }

    /// Stores `token` in memory and in ``storage``. Called by auth flows
    /// after an initial token grant.
    public func store(_ token: Token) async throws {
        cached = token
        let data = try JSONEncoder.iso8601.encode(token)
        guard let json = String(data: data, encoding: .utf8) else {
            throw OAuthError(rawCode: "encoding_failed", message: "could not encode token", status: 500)
        }
        try await storage.set(json, for: storageKey)
    }

    /// Removes the stored token. Used by sign-out flows.
    public func clear() async throws {
        cached = nil
        try await storage.delete(for: storageKey)
    }

    public func currentToken() async throws -> Token {
        if let token = try await loadCached(), !token.isExpired {
            return token
        }
        return try await refresh()
    }

    public func invalidate() async {
        cached = nil
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

    /// Calls `/auth/token` with `grant_type=refresh_token`, persists the
    /// returned bundle, and returns it.
    private func refresh() async throws -> Token {
        guard let refreshToken = try await loadCached()?.refreshToken else {
            throw OAuthError(
                rawCode: "invalid_grant",
                message: "no refresh token available — re-authenticate",
                status: 401
            )
        }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ]
        request.httpBody = formURLEncode(body).data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError(rawCode: "invalid_response", message: "no HTTP response", status: 500)
        }

        if !(200..<300).contains(http.statusCode) {
            throw try parseOAuthError(data: data, status: http.statusCode)
        }

        let token = try JSONDecoder.iso8601.decode(Token.self, from: data)
        try await store(token)
        return token
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
