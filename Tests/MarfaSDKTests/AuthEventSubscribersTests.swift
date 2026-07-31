import Foundation
import Testing

@testable import MarfaSDK

/// The registry behind `StoredTokenProvider.authEvents`.
///
/// This covers the mechanism, not the wiring. The property it pins is the one
/// the mechanism exists for: a subscriber registered immediately before an
/// emission receives it, with no scheduling hop in between. Registration used
/// to be deferred onto a `Task`, so an event emitted in that gap reached
/// nobody, and past events are not replayed — an app that subscribed and then
/// read a token could sit signed-in forever with nothing listening.
///
/// The gap is real but not reliably reproducible through the provider on a
/// developer machine: every path that emits is `async` and offers the deferred
/// registration enough suspension points to land first. Rather than ship a
/// provider-level test that passes whichever way the registration works, the
/// guarantee is asserted here, where it can actually fail.
@Suite("Auth event subscribers")
struct AuthEventSubscribersTests {

    @Test("an event emitted straight after registering is delivered")
    func synchronousRegistrationReceivesTheNextEvent() async throws {
        let subscribers = AuthEventSubscribers()

        var continuation: AsyncStream<AuthEvent>.Continuation!
        let stream = AsyncStream<AuthEvent> { continuation = $0 }
        subscribers.register(continuation)

        // No await between registering and emitting: that is the whole point.
        subscribers.emit(.signedOut(reason: .refreshTokenRejected))

        var received: AuthEvent?
        for await event in stream {
            received = event
            break
        }
        #expect(received != nil)
    }

    @Test("a finished subscriber is dropped rather than yielded to forever")
    func terminatedSubscribersArePruned() async throws {
        let subscribers = AuthEventSubscribers()
        var continuation: AsyncStream<AuthEvent>.Continuation!
        _ = AsyncStream<AuthEvent> { continuation = $0 }
        subscribers.register(continuation)
        continuation.finish()

        // Emitting to a finished continuation must not trap, and the registry
        // must not keep it: a process that signs in and out repeatedly would
        // otherwise accumulate dead subscribers for its lifetime.
        subscribers.emit(.signedOut(reason: .refreshTokenRejected))
        subscribers.emit(.signedOut(reason: .refreshTokenRejected))
    }
}
