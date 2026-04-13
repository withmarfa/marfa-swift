import Foundation

/// Configuration for connecting to a Myme server.
public struct ClientConfiguration: Sendable {

    /// The base URL of the Myme API (e.g., `http://localhost:8600`).
    public let url: URL

    /// The API key for authentication. Sent as a Bearer token.
    public let apiKey: String

    /// Default conflict resolution strategy for updates. Can be overridden per-call.
    public var conflictStrategy: ConflictStrategy

    /// Timeout for individual HTTP requests in seconds.
    public var timeoutInterval: TimeInterval

    /// Timeout for resource loading (large uploads/downloads) in seconds.
    public var resourceTimeout: TimeInterval

    /// Optional CDN base URL for blob retrieval. Falls back to `url` if `nil`.
    public var cdnBaseURL: URL?

    public init(
        url: URL,
        apiKey: String,
        conflictStrategy: ConflictStrategy = .auto,
        timeoutInterval: TimeInterval = 30,
        resourceTimeout: TimeInterval = 120,
        cdnBaseURL: URL? = nil
    ) {
        self.url = url
        self.apiKey = apiKey
        self.conflictStrategy = conflictStrategy
        self.timeoutInterval = timeoutInterval
        self.resourceTimeout = resourceTimeout
        self.cdnBaseURL = cdnBaseURL
    }

    /// Creates a configuration from environment variables.
    ///
    /// Reads `MYME_API_URL` and `MYME_API_KEY` from the process environment.
    /// Returns `nil` if either is missing or empty.
    public static func fromEnvironment() -> ClientConfiguration? {
        let env = ProcessInfo.processInfo.environment
        guard let urlString = env["MYME_API_URL"], !urlString.isEmpty,
              let url = URL(string: urlString),
              let key = env["MYME_API_KEY"], !key.isEmpty else {
            return nil
        }
        return ClientConfiguration(url: url, apiKey: key)
    }
}
