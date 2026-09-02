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

    /// Timeout bounding the whole life of an ordinary request, in seconds —
    /// what a large upload or download is allowed to take.
    ///
    /// It does not govern the event stream. A stream is a request with no
    /// natural end, so it carries no resource timeout at all and is bounded
    /// by silence instead. See ``streamTimeout``.
    public var resourceTimeout: TimeInterval

    /// Inactivity timeout for the event stream, in seconds.
    ///
    /// This measures silence rather than duration: every frame the server
    /// sends resets it, and a stream that is delivering is never ended by
    /// it. Since the stream carries no resource timeout, this is the only
    /// thing that ends one the server has stopped feeding.
    ///
    /// The default is twice the server's thirty-second heartbeat, which is
    /// also the bound the realtime guide publishes for any SSE client: a
    /// stream is declared dead only once a whole ping interval has passed
    /// unheard, so one late or dropped heartbeat does not tear it down.
    /// Raise it for a deployment whose proxy batches SSE frames. A value
    /// below the server's heartbeat interval tears down healthy streams.
    public var streamTimeout: TimeInterval

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
        streamTimeout: TimeInterval = 60,
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
        self.streamTimeout = streamTimeout
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
        streamTimeout: TimeInterval = 60,
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
        self.streamTimeout = streamTimeout
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
        fromEnvironment(ProcessInfo.processInfo.environment)
    }

    /// The resolution itself, over a supplied environment.
    ///
    /// Split from the public entry point because the process environment is
    /// ambient: a developer with `MARFA_API_URL` and `MARFA_API_KEY`
    /// exported — the pair the CLI and MCP server read — changes what the
    /// public overload returns, so a test written against it either depends
    /// on the machine it runs on or asserts nothing at all.
    static func fromEnvironment(_ env: [String: String]) -> ClientConfiguration? {
        guard let urlString = env["MARFA_API_URL"], !urlString.isEmpty,
              let url = URL(string: urlString),
              let key = env["MARFA_API_KEY"], !key.isEmpty else {
            return nil
        }
        return ClientConfiguration(url: url, apiKey: key)
    }
}
