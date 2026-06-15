import Foundation

/// Bounded exponential back-off policy for transport retries.
///
/// The transport consults this before repeating a failed request. Default
/// values (`maxAttempts = 3`, `baseDelay = 0.25s`, `maxDelay = 10s`,
/// `jitter = 0.2`) give three total attempts with delays around 250ms,
/// 500ms, and 1s — fast enough for brief network blips, slow enough to
/// avoid hammering the server.
///
/// Retry eligibility depends on both the HTTP method and the failure shape;
/// see ``shouldRetry(method:statusCode:urlError:)``.
public struct RetryPolicy: Sendable, Equatable {

    /// Total attempt count including the first. `1` means no retry;
    /// `3` means two retries after the initial attempt.
    public var maxAttempts: Int

    /// Base delay in seconds before the first retry. Subsequent retries use
    /// exponential back-off capped at `maxDelay`.
    public var baseDelay: TimeInterval

    /// Upper bound on any single delay, after back-off and jitter.
    public var maxDelay: TimeInterval

    /// Jitter fraction applied to each delay (0.0 to 1.0). `0.2` adds up to
    /// ±20% randomness to smooth synchronized retries across clients.
    public var jitter: Double

    /// When `true`, a `Retry-After` header on a 429 or 503 response
    /// overrides the computed delay.
    public var honorsRetryAfter: Bool

    public init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 0.25,
        maxDelay: TimeInterval = 10,
        jitter: Double = 0.2,
        honorsRetryAfter: Bool = true
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
        self.jitter = min(max(0, jitter), 1)
        self.honorsRetryAfter = honorsRetryAfter
    }

    /// Conventional default.
    public static let `default` = RetryPolicy()

    /// Disables retries entirely. `maxAttempts == 1`.
    public static let none = RetryPolicy(maxAttempts: 1)

    /// Computed exponential back-off with jitter for the given 1-based attempt.
    /// Attempt 1 returns 0 (no delay before the first attempt).
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        let exponent = Double(attempt - 2)
        let raw = baseDelay * pow(2.0, exponent)
        let capped = min(raw, maxDelay)
        guard jitter > 0 else { return capped }
        let j = Double.random(in: -jitter...jitter)
        return max(0, capped * (1 + j))
    }

    /// Returns `true` if the transport should retry given the method,
    /// the response status code (if any), and the URLError (if any).
    ///
    /// - 429 and 503 are always retryable regardless of method (server
    ///   requested back-off).
    /// - 500, 502, 504 are retryable only on idempotent methods.
    /// - Known-transient `URLError` codes are always retryable (connection
    ///   didn't complete, so idempotence doesn't apply).
    /// - Everything else is non-retryable.
    public func shouldRetry(
        method: HTTPMethod,
        statusCode: Int?,
        urlError: URLError?
    ) -> Bool {
        if let urlError, Self.transientURLErrorCodes.contains(urlError.code) {
            return true
        }
        guard let statusCode else { return false }
        if statusCode == 429 || statusCode == 503 {
            return true
        }
        if [500, 502, 504].contains(statusCode), method.isIdempotent {
            return true
        }
        return false
    }

    /// `URLError.Code`s the transport treats as transient connection
    /// failures. Retrying them is safe on any method because the request
    /// didn't complete on the server.
    static let transientURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .networkConnectionLost,
        .notConnectedToInternet,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
    ]
}

extension HTTPMethod {
    /// RFC 7231 idempotency for retry decisions.
    var isIdempotent: Bool {
        switch self {
        case .get, .head, .put, .delete: return true
        case .post, .patch: return false
        }
    }
}
