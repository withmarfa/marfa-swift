import Testing
import Foundation
@testable import MarfaSDK

@Suite("RateLimitState")
struct RateLimitStateTests {

    @Test("Starts empty")
    func startsEmpty() async {
        let state = RateLimitState()
        #expect(await state.remaining == nil)
        #expect(await state.reset == nil)
        #expect(await state.lastRetryAfter == nil)
    }

    @Test("Updates remaining from header")
    func updatesRemaining() async {
        let state = RateLimitState()
        await state.update(from: ["X-RateLimit-Remaining": "42"])
        #expect(await state.remaining == 42)
    }

    @Test("Updates Retry-After from header")
    func updatesRetryAfter() async {
        let state = RateLimitState()
        await state.update(from: ["Retry-After": "30"])
        #expect(await state.lastRetryAfter == 30)
    }

    @Test("X-RateLimit-Reset treated as epoch when large")
    func resetAsEpoch() async {
        let state = RateLimitState()
        let future = Date().timeIntervalSince1970 + 600  // +10 min
        await state.update(from: ["X-RateLimit-Reset": "\(Int(future))"])
        let reset = await state.reset
        let diff = abs(reset!.timeIntervalSince1970 - future)
        #expect(diff < 1)
    }

    @Test("X-RateLimit-Reset treated as duration when small")
    func resetAsDuration() async {
        let state = RateLimitState()
        let now = Date()
        await state.update(from: ["X-RateLimit-Reset": "60"], now: now)
        let reset = await state.reset
        let diff = abs(reset!.timeIntervalSince1970 - (now.timeIntervalSince1970 + 60))
        #expect(diff < 1)
    }

    @Test("Header lookup is case-insensitive")
    func caseInsensitive() async {
        let state = RateLimitState()
        await state.update(from: ["x-ratelimit-remaining": "5", "retry-after": "10"])
        #expect(await state.remaining == 5)
        #expect(await state.lastRetryAfter == 10)
    }

    @Test("Clear resets everything")
    func clearResets() async {
        let state = RateLimitState()
        await state.update(from: [
            "X-RateLimit-Remaining": "100",
            "X-RateLimit-Reset": "60",
            "Retry-After": "5",
        ])
        await state.clear()
        #expect(await state.remaining == nil)
        #expect(await state.reset == nil)
        #expect(await state.lastRetryAfter == nil)
    }
}
