import Foundation
import Testing

@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// `MarfaAuth.clearStoredCredentials` — the supported way to remove a stored
/// grant without a token provider.
///
/// It exists because the key spelling is the SDK's and a consumer cannot see
/// it: `OAuthIssuer` is internal. An app that rebuilt the key by hand could
/// only ever encode the spelling that was right when it was written, and this
/// SDK changed it — so the delete addressed an empty slot, reported success,
/// and left a live credential on a device the user had signed out of.
///
/// The keys are constructed here through `OAuthIssuer` rather than written out,
/// which is correct on this side of the boundary: this is the component that
/// owns the format, so agreeing with itself is the property under test.
@Suite("Clearing stored credentials")
struct ClearStoredCredentialsTests {

    private let issuer = URL(string: "https://auth.example.test")!
    private let clientId = "client-abc"

    @Test("removes the token and the pending authorization")
    func removesCurrentSpellings() async throws {
        let storage = InMemoryKeychain()
        let tokensKey = OAuthIssuer.storageKey(
            kind: "tokens", issuer: issuer, clientId: clientId
        )
        let pendingKey = OAuthIssuer.storageKey(
            kind: "pending", issuer: issuer, clientId: clientId
        )
        try await storage.set("live-token", for: tokensKey)
        try await storage.set("half-finished", for: pendingKey)

        try await MarfaAuth.clearStoredCredentials(
            issuer: issuer, clientId: clientId, storage: storage
        )

        #expect(try await storage.get(for: tokensKey) == nil)
        #expect(try await storage.get(for: pendingKey) == nil)
    }

    @Test("removes the pre-11.4.0 spelling too")
    func removesTheLegacySpelling() async throws {
        // An install that upgraded but never restored a session still has the
        // credential under the old key, because the migration that moves it
        // runs on restore.
        let storage = InMemoryKeychain()
        let legacyTokens = OAuthIssuer.legacyStorageKey(
            kind: "tokens", issuer: issuer, clientId: clientId
        )
        let legacyPending = OAuthIssuer.legacyStorageKey(
            kind: "pending", issuer: issuer, clientId: clientId
        )
        try await storage.set("live-token", for: legacyTokens)
        try await storage.set("half-finished", for: legacyPending)

        try await MarfaAuth.clearStoredCredentials(
            issuer: issuer, clientId: clientId, storage: storage
        )

        #expect(try await storage.get(for: legacyTokens) == nil)
        // The pending account too. Only the token account is migrated on
        // restore, so a half-finished authorization can still be sitting under
        // the old spelling when the user signs out.
        #expect(try await storage.get(for: legacyPending) == nil)
    }

    @Test("leaves another account's credential alone")
    func leavesOtherAccountsAlone() async throws {
        let storage = InMemoryKeychain()
        let otherKey = OAuthIssuer.storageKey(
            kind: "tokens", issuer: issuer, clientId: "someone-else"
        )
        try await storage.set("their-token", for: otherKey)

        try await MarfaAuth.clearStoredCredentials(
            issuer: issuer, clientId: clientId, storage: storage
        )

        #expect(try await storage.get(for: otherKey) == "their-token")
    }

    @Test("an issuer spelled with a trailing slash addresses the same rows")
    func trailingSlashIsTheSameAccount() async throws {
        // Storage keys are canonicalized, so the two spellings are one account.
        // Without that, signing out through one and back in through the other
        // would leave a credential behind under the spelling nobody used.
        let storage = InMemoryKeychain()
        let tokensKey = OAuthIssuer.storageKey(
            kind: "tokens", issuer: issuer, clientId: clientId
        )
        try await storage.set("live-token", for: tokensKey)

        try await MarfaAuth.clearStoredCredentials(
            issuer: URL(string: "https://auth.example.test/")!,
            clientId: clientId,
            storage: storage
        )

        #expect(try await storage.get(for: tokensKey) == nil)
    }
}
