import Testing
import Foundation
@testable import MymeSDK

@Suite("RetryPolicy")
struct RetryPolicyTests {

    @Test("Default policy has maxAttempts 3")
    func defaultAttempts() {
        #expect(RetryPolicy.default.maxAttempts == 3)
    }

    @Test("none policy has maxAttempts 1")
    func nonePolicyDisablesRetries() {
        #expect(RetryPolicy.none.maxAttempts == 1)
    }

    @Test("Attempt 1 delay is zero")
    func firstAttemptHasNoDelay() {
        let p = RetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 10, jitter: 0)
        #expect(p.delay(forAttempt: 1) == 0)
    }

    @Test("Delay doubles between attempts (no jitter)")
    func exponentialBackoff() {
        let p = RetryPolicy(maxAttempts: 5, baseDelay: 0.5, maxDelay: 60, jitter: 0)
        #expect(p.delay(forAttempt: 2) == 0.5)
        #expect(p.delay(forAttempt: 3) == 1.0)
        #expect(p.delay(forAttempt: 4) == 2.0)
        #expect(p.delay(forAttempt: 5) == 4.0)
    }

    @Test("Delay capped at maxDelay")
    func capped() {
        let p = RetryPolicy(maxAttempts: 10, baseDelay: 1, maxDelay: 3, jitter: 0)
        #expect(p.delay(forAttempt: 6) == 3.0) // would be 32 uncapped
    }

    @Test("Jitter produces variation within ±range")
    func jitterSpread() {
        let p = RetryPolicy(maxAttempts: 5, baseDelay: 1, maxDelay: 10, jitter: 0.3)
        for _ in 0..<50 {
            let d = p.delay(forAttempt: 2)
            #expect(d >= 0.7 && d <= 1.3)
        }
    }

    @Test("Retryable: 429 always (any method)")
    func retry429() {
        let p = RetryPolicy.default
        #expect(p.shouldRetry(method: .post, statusCode: 429, urlError: nil))
        #expect(p.shouldRetry(method: .get, statusCode: 429, urlError: nil))
        #expect(p.shouldRetry(method: .patch, statusCode: 429, urlError: nil))
    }

    @Test("Retryable: 503 always (any method)")
    func retry503() {
        let p = RetryPolicy.default
        #expect(p.shouldRetry(method: .post, statusCode: 503, urlError: nil))
        #expect(p.shouldRetry(method: .delete, statusCode: 503, urlError: nil))
    }

    @Test("Retryable: 500/502/504 only on idempotent methods")
    func retry5xxIdempotent() {
        let p = RetryPolicy.default
        #expect(p.shouldRetry(method: .get, statusCode: 500, urlError: nil))
        #expect(p.shouldRetry(method: .put, statusCode: 502, urlError: nil))
        #expect(p.shouldRetry(method: .delete, statusCode: 504, urlError: nil))
        #expect(!p.shouldRetry(method: .post, statusCode: 500, urlError: nil))
        #expect(!p.shouldRetry(method: .patch, statusCode: 502, urlError: nil))
    }

    @Test("Non-retryable: 4xx other than 429")
    func noRetryOn4xx() {
        let p = RetryPolicy.default
        #expect(!p.shouldRetry(method: .get, statusCode: 400, urlError: nil))
        #expect(!p.shouldRetry(method: .get, statusCode: 401, urlError: nil))
        #expect(!p.shouldRetry(method: .get, statusCode: 403, urlError: nil))
        #expect(!p.shouldRetry(method: .get, statusCode: 404, urlError: nil))
    }

    @Test("Retryable: transient URLError codes (any method)")
    func retryTransientURLError() {
        let p = RetryPolicy.default
        let codes: [URLError.Code] = [
            .timedOut, .networkConnectionLost, .notConnectedToInternet,
            .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        ]
        for code in codes {
            #expect(p.shouldRetry(method: .post, statusCode: nil, urlError: URLError(code)))
            #expect(p.shouldRetry(method: .get, statusCode: nil, urlError: URLError(code)))
        }
    }

    @Test("Non-retryable: URLError.cancelled")
    func noRetryOnCancel() {
        let p = RetryPolicy.default
        #expect(!p.shouldRetry(method: .get, statusCode: nil, urlError: URLError(.cancelled)))
    }

    @Test("HTTPMethod idempotency")
    func methodIdempotency() {
        #expect(HTTPMethod.get.isIdempotent)
        #expect(HTTPMethod.head.isIdempotent)
        #expect(HTTPMethod.put.isIdempotent)
        #expect(HTTPMethod.delete.isIdempotent)
        #expect(!HTTPMethod.post.isIdempotent)
        #expect(!HTTPMethod.patch.isIdempotent)
    }
}
