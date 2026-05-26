import Foundation

/// Thread-safe snapshot of the most recent `X-RateLimit-*` headers seen by
/// the transport. Consumers can inspect `remaining`, `reset`, and
/// `lastRetryAfter` for UI hints (e.g., "slow down, 10 requests left")
/// without racing the transport's own reads.
public actor RateLimitState {

    /// Value of `X-RateLimit-Remaining` from the last response that carried it.
    public private(set) var remaining: Int?

    /// Derived from `X-RateLimit-Reset`. The header may be a Unix epoch
    /// seconds value or a number of seconds until reset; both are handled.
    public private(set) var reset: Date?

    /// Most recent `Retry-After` value (seconds) observed on a 429 or 503.
    public private(set) var lastRetryAfter: TimeInterval?

    public init() {}

    /// Updates state from an HTTP response's headers.
    public func update(from headers: [AnyHashable: Any], now: Date = Date()) {
        if let remainingValue = Self.headerInt(headers, key: "X-RateLimit-Remaining") {
            remaining = remainingValue
        }
        if let resetValue = Self.headerDouble(headers, key: "X-RateLimit-Reset") {
            if resetValue > 1_000_000 {
                // Looks like a Unix timestamp in seconds.
                reset = Date(timeIntervalSince1970: resetValue)
            } else {
                // Looks like a duration in seconds.
                reset = now.addingTimeInterval(resetValue)
            }
        }
        if let retryAfter = Self.headerDouble(headers, key: "Retry-After") {
            lastRetryAfter = retryAfter
        }
    }

    /// Clears all state. Useful for tests and manual resets.
    public func clear() {
        remaining = nil
        reset = nil
        lastRetryAfter = nil
    }

    // MARK: - Header lookups (case-insensitive)

    private static func headerValue(_ headers: [AnyHashable: Any], key: String) -> String? {
        for (k, v) in headers {
            if let ks = k as? String, ks.caseInsensitiveCompare(key) == .orderedSame {
                if let sv = v as? String { return sv }
                if let nv = v as? NSNumber { return nv.stringValue }
                return String(describing: v)
            }
        }
        return nil
    }

    private static func headerInt(_ headers: [AnyHashable: Any], key: String) -> Int? {
        headerValue(headers, key: key).flatMap(Int.init)
    }

    private static func headerDouble(_ headers: [AnyHashable: Any], key: String) -> Double? {
        headerValue(headers, key: key).flatMap(Double.init)
    }
}
