import Foundation

/// Configuration for connecting to a Marfa server.
public struct ClientConfiguration: Sendable {

    /// The base URL of the Marfa API (e.g., `http://localhost:8600`).
    public let url: URL

    /// The API key for authentication. Empty string when the client was
    /// constructed with a custom ``TokenProvider`` (e.g. via OAuth);
    /// non-empty for the static-key path.
    ///
    /// Internally, the SDK reaches for ``tokenProvider`` on every request.
    /// `apiKey` is exposed on the surface so callers that round-trip an
    /// API key (notably
    /// ``MarfaClient/saveToKeychain(service:account:accessGroup:)``) can
    /// read it back.
    public let apiKey: String

    /// Internal auth contract — the transport awaits
    /// ``TokenProvider/currentToken()`` for every request.
    ///
    /// For the API-key path this is a ``StaticTokenProvider`` constructed
    /// from ``apiKey``. For OAuth flows it's a ``StoredTokenProvider`` (or
    /// a custom implementation) that may refresh on demand.
    internal let tokenProvider: any TokenProvider

    /// Default conflict resolution strategy for updates. Can be overridden per-call.
    public var conflictStrategy: ConflictStrategy

    /// Timeout for individual HTTP requests in seconds.
    public var timeoutInterval: TimeInterval

    /// Timeout for resource loading (large uploads/downloads) in seconds.
    public var resourceTimeout: TimeInterval

    /// Optional CDN base URL for blob retrieval. Falls back to `url` if `nil`.
    public var cdnBaseURL: URL?

    /// When `true`, the transport logs full request and response headers
    /// and bodies at the `.debug` level with `.private` privacy. Off by
    /// default; headers and bodies stay redacted in regular logs either way.
    public var debugLogging: Bool

    /// Policy controlling retry attempts on transient failures, 429/503,
    /// and idempotent-method 5xx responses.
    public var retryPolicy: RetryPolicy

    /// Maximum concurrent per-target calls made by
    /// ``EdgesNamespace/listToTargets(targetIds:edgeType:limit:)`` in
    /// remote mode. Ignored in synced / pure-local mode, where the batched
    /// lookup is a single local SQL query. Default `8` — conservative
    /// against server rate limits while keeping realistic thread/feed
    /// fan-outs fast. Values `< 1` are clamped to `1`.
    public var maxBackrefBatchConcurrency: Int

    public init(
        url: URL,
        apiKey: String,
        conflictStrategy: ConflictStrategy = .auto,
        timeoutInterval: TimeInterval = 30,
        resourceTimeout: TimeInterval = 120,
        cdnBaseURL: URL? = nil,
        debugLogging: Bool = false,
        retryPolicy: RetryPolicy = .default,
        maxBackrefBatchConcurrency: Int = 8
    ) {
        self.url = url
        self.apiKey = apiKey
        self.tokenProvider = StaticTokenProvider(apiKey: apiKey)
        self.conflictStrategy = conflictStrategy
        self.timeoutInterval = timeoutInterval
        self.resourceTimeout = resourceTimeout
        self.cdnBaseURL = cdnBaseURL
        self.debugLogging = debugLogging
        self.retryPolicy = retryPolicy
        self.maxBackrefBatchConcurrency = maxBackrefBatchConcurrency
    }

    /// OAuth-tokened initializer — accepts a ``TokenProvider`` directly,
    /// bypassing the API-key field. Used internally by
    /// ``MarfaClient/init(url:tokenProvider:)`` and
    /// ``MarfaClient/synced(url:tokenProvider:storePath:connectionManager:)``.
    public init(
        url: URL,
        tokenProvider: any TokenProvider,
        conflictStrategy: ConflictStrategy = .auto,
        timeoutInterval: TimeInterval = 30,
        resourceTimeout: TimeInterval = 120,
        cdnBaseURL: URL? = nil,
        debugLogging: Bool = false,
        retryPolicy: RetryPolicy = .default,
        maxBackrefBatchConcurrency: Int = 8
    ) {
        self.url = url
        self.apiKey = ""
        self.tokenProvider = tokenProvider
        self.conflictStrategy = conflictStrategy
        self.timeoutInterval = timeoutInterval
        self.resourceTimeout = resourceTimeout
        self.cdnBaseURL = cdnBaseURL
        self.debugLogging = debugLogging
        self.retryPolicy = retryPolicy
        self.maxBackrefBatchConcurrency = maxBackrefBatchConcurrency
    }

    /// Creates a configuration from environment variables.
    ///
    /// Reads `MARFA_API_URL` and `MARFA_API_KEY` from the process environment.
    /// Returns `nil` if either is missing or empty.
    public static func fromEnvironment() -> ClientConfiguration? {
        let env = ProcessInfo.processInfo.environment
        guard let urlString = env["MARFA_API_URL"], !urlString.isEmpty,
              let url = URL(string: urlString),
              let key = env["MARFA_API_KEY"], !key.isEmpty else {
            return nil
        }
        return ClientConfiguration(url: url, apiKey: key)
    }
}
