import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// A store knows which server it belongs to.
///
/// **There is nothing to reconcile, which is why this refuses.** A store holds
/// one server's rows, one event cursor and a queue of writes addressed to that
/// server. Opening it against a different origin does not produce a store with
/// two servers' data in it — it produces one where every later answer
/// overwrites rows that were never the same rows, and a queue that replays
/// somebody's edits at a server that has never heard of them. Nothing
/// afterwards tells that apart from ordinary drift.
@Suite("A store knows whose it is", .timeLimit(.minutes(1)))
struct StoreIdentityTests {

    private func queue() async throws -> MutationQueue {
        let (_, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        return queue
    }

    @Test("an unclaimed store takes the origin that opens it")
    func anUnclaimedStoreIsClaimed() async throws {
        let queue = try await queue()
        #expect(try await queue.claimedOrigin() == nil)

        try await queue.claimOrigin("https://api.marfa.so")
        #expect(try await queue.claimedOrigin() == "https://api.marfa.so")
    }

    @Test("reopening against the same origin is not a mismatch")
    func theSameOriginReopens() async throws {
        let queue = try await queue()
        try await queue.claimOrigin("https://api.marfa.so")
        try await queue.claimOrigin("https://api.marfa.so")
    }

    /// The failure this exists for: a store built against staging opened
    /// against production, or the reverse.
    @Test("another origin is refused, and the refusal names both")
    func anotherOriginIsRefused() async throws {
        let queue = try await queue()
        try await queue.claimOrigin("https://staging.marfa.so")

        let thrown = await #expect(throws: StoreIdentityMismatchError.self) {
            try await queue.claimOrigin("https://api.marfa.so")
        }
        #expect(thrown?.axis == .origin)
        #expect(thrown?.recorded == "https://staging.marfa.so")
        #expect(thrown?.found == "https://api.marfa.so")
        // Permanent by construction: nothing about a later attempt differs,
        // so a queue that retried this would retry it for ever.
        #expect(thrown?.isPermanent == true)
    }

    /// **A trailing slash is the same server**, and refusing over it would be
    /// a false refusal on a difference nobody made. `ClientConfiguration`
    /// takes whatever URL a consumer passes.
    @Test("two spellings of one server are one origin")
    func spellingsAreNormalized() {
        let plain = MarfaClient.canonicalOrigin(URL(string: "https://api.marfa.so")!)
        let slashed = MarfaClient.canonicalOrigin(URL(string: "https://api.marfa.so/")!)
        let shouted = MarfaClient.canonicalOrigin(URL(string: "https://API.Marfa.so")!)
        #expect(plain == slashed)
        #expect(plain == shouted)

        // The discriminator: normalization must not collapse two real servers.
        let other = MarfaClient.canonicalOrigin(URL(string: "https://staging.marfa.so")!)
        #expect(plain != other)
    }
}
