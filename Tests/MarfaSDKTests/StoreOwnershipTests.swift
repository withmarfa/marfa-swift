import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// Which account a store belongs to, and the failure directions around it.
///
/// The reproduction at the bottom is why this exists. Before it, a populated
/// store could be pointed at a second account's credential and the SDK had
/// nothing to say about it — so each consumer invented a guard, and the one
/// that shipped compared API-key hashes, which are only ever written when a key
/// is saved. An install that reached its first account by OAuth had nothing
/// recorded, the guard stayed silent, and the first account's library uploaded
/// into the second account's space.
@Suite("Which account a store belongs to")
struct StoreOwnershipTests {

    private let serverURL = URL(string: "https://api.example.test")!

    /// A network-backed client whose `/auth/me` answers with `spaceId`.
    private func credentialClient(spaceId: String) -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: serverURL, apiKey: "k")
        let client = MarfaClient(configuration: config, transport: mock)
        mock.enqueue(AuthMe(
            space: AuthMeSpace(createdAt: "2026-08-26T09:00:00Z", id: spaceId, name: "S"),
            user: nil
        ))
        return (client, mock)
    }

    private func identity(_ spaceId: String) -> MarfaAccountIdentity {
        MarfaAccountIdentity(serverURL: serverURL, spaceId: spaceId)
    }

    // MARK: - Identity

    @Test("the identity comes from the space, not the user")
    func identityReadsTheSpace() async throws {
        // `user` is nil for an API key, which is the ordinary case. Reading
        // identity from `user` would work under OAuth and fail under a key —
        // and "stable across auth methods" is the whole requirement.
        let (client, _) = credentialClient(spaceId: "space-1")
        let resolved = try await client.accountIdentity()
        #expect(resolved.spaceId == "space-1")
        #expect(resolved == identity("space-1"))
    }

    @Test("two credentials for one account produce one identity")
    func identityIsStableAcrossCredentials() async throws {
        // The property an API-key hash cannot have: one account can hold
        // several keys and be reached by more than one auth method.
        let (first, _) = credentialClient(spaceId: "space-1")
        let (second, _) = credentialClient(spaceId: "space-1")
        #expect(try await first.accountIdentity() == (try await second.accountIdentity()))
    }

    @Test("the server URL is canonicalized into the identity")
    func identityCanonicalizesTheServer() {
        let plain = MarfaAccountIdentity(
            serverURL: URL(string: "https://api.example.test")!, spaceId: "s")
        let shouty = MarfaAccountIdentity(
            serverURL: URL(string: "HTTPS://API.EXAMPLE.TEST:443/")!, spaceId: "s")
        // Otherwise one account reads as two depending on how the URL was typed.
        #expect(plain == shouty)
        #expect(plain.storageKey == shouty.storageKey)
    }

    @Test("the same space on two servers is two identities")
    func identityIsScopedToTheServer() {
        let staging = MarfaAccountIdentity(
            serverURL: URL(string: "https://staging.example.test")!, spaceId: "s")
        let production = MarfaAccountIdentity(
            serverURL: URL(string: "https://api.example.test")!, spaceId: "s")
        #expect(staging != production)
    }

    // MARK: - Ownership

    @Test("a store nothing has claimed reports unclaimed")
    func unclaimedStore() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        #expect(try await client.storeOwnership(for: identity("space-1")) == .unclaimed)
    }

    @Test("a store claimed by this account reports the same account")
    func sameAccount() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        try await client.claimStore(for: identity("space-1"))
        #expect(try await client.storeOwnership(for: identity("space-1")) == .sameAccount)
    }

    @Test("the claim survives a fresh client over the same store")
    func claimIsPersisted() async throws {
        let container = try MarfaSDKTest.makeInMemoryContainer()
        let first = try await MarfaClient.local(container: container)
        try await first.claimStore(for: identity("space-1"))

        let second = try await MarfaClient.local(container: container)
        #expect(try await second.storeOwnership(for: identity("space-1")) == .sameAccount)
    }

    @Test("releasing the claim makes the next sign-in a first one")
    func releasingTheClaim() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        try await client.claimStore(for: identity("space-1"))
        try await client.releaseStoreClaim()
        #expect(try await client.storeOwnership(for: identity("space-1")) == .unclaimed)
    }

    // MARK: - The reproduction

    @Test("the cross-account case: one account's store is not owned by another")
    func crossAccountStoreIsRefused() async throws {
        // Sign in to account A and let the store become A's.
        let store = try await MarfaSDKTest.makeInMemoryClient()
        try await store.claimStore(for: identity("space-A"))

        // Sign out keeping items — the store stays, full of A's library — then
        // connect a credential for account B.
        let (bCredential, _) = credentialClient(spaceId: "space-B")

        let ownership = try await store.storeOwnership(resolvedWith: bCredential)

        // Before this existed the answer was silence, and A's whole library
        // went into B's space. Nothing here decides what to *do* about it —
        // that is the consumer's policy — but it can no longer be missed.
        #expect(ownership == .differentAccount)
    }

    @Test("resolved with the same account's credential it reports the same account")
    func resolvedSameAccount() async throws {
        let store = try await MarfaSDKTest.makeInMemoryClient()
        try await store.claimStore(for: identity("space-A"))
        let (aCredential, _) = credentialClient(spaceId: "space-A")
        #expect(try await store.storeOwnership(resolvedWith: aCredential) == .sameAccount)
    }

    // MARK: - The failure direction

    @Test("a credential that cannot be resolved reports unresolved, never sameAccount")
    func unresolvedIsNotSameAccount() async throws {
        let store = try await MarfaSDKTest.makeInMemoryClient()
        try await store.claimStore(for: identity("space-A"))

        // Offline, or a credential the server refused: nothing queued, so the
        // `/auth/me` call fails.
        let mock = MockTransport()
        let config = ClientConfiguration(url: serverURL, apiKey: "k")
        let unreachable = MarfaClient(configuration: config, transport: mock)

        let ownership = try await store.storeOwnership(resolvedWith: unreachable)

        // The case that must not collapse into `.sameAccount`. A wipe should
        // read this as "do nothing" and an upload must read it as "stop", and a
        // single boolean cannot carry both.
        #expect(ownership == .unresolved)
        #expect(ownership != .sameAccount)
    }

    // MARK: - Asking is not claiming

    @Test("asking the question does not answer it for next time")
    func askingDoesNotClaim() async throws {
        let store = try await MarfaSDKTest.makeInMemoryClient()
        let (credential, _) = credentialClient(spaceId: "space-A")

        #expect(try await store.storeOwnership(resolvedWith: credential) == .unclaimed)

        // Still unclaimed. If asking recorded, a second attempt after a failed
        // upload would read `.sameAccount` and skip the check that protects it.
        #expect(try await store.storeOwnership(for: identity("space-A")) == .unclaimed)
    }

    // MARK: - Misuse

    @Test("a client with no store says so rather than answering")
    func storelessClientThrows() async throws {
        let config = ClientConfiguration(url: serverURL, apiKey: "k")
        let networkOnly = MarfaClient(configuration: config, transport: MockTransport())

        await #expect(throws: NoLocalStoreError.self) {
            _ = try await networkOnly.storeOwnership(for: self.identity("space-1"))
        }
        await #expect(throws: NoLocalStoreError.self) {
            try await networkOnly.claimStore(for: self.identity("space-1"))
        }
    }

    @Test("a local client cannot resolve an identity, and says which call needed a server")
    func localClientCannotResolveIdentity() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.accountIdentity()
        }
    }
}
