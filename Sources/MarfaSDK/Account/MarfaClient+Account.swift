import Foundation

/// Raised when an ownership question is asked of a client that has no store to
/// ask it about.
public struct NoLocalStoreError: Error, Sendable, Equatable {
    /// The operation that needed a store.
    public let operation: String
}

extension NoLocalStoreError: LocalizedError {
    public var errorDescription: String? {
        "\(operation) needs a client with a local store. "
            + "This client was built without one, so there is nothing to own."
    }
}

extension MarfaClient {

    /// Resolve which account this client's credential reaches.
    ///
    /// One network call, `GET /auth/me`, and the answer is stable across a
    /// credential rotation and across auth methods — which is what makes it
    /// usable as an identity where a token or an API key is not.
    ///
    /// - Important: Ask this on a **network-backed client built with the
    ///   credential in question**. A synced client would answer about the
    ///   credential it was already holding, which is the old question, and this
    ///   is usually being asked precisely because a new credential has arrived.
    ///   `MarfaClient(url:apiKey:)` and `MarfaClient(url:tokenProvider:)` both
    ///   build a client with no store, which is what you want here.
    public func accountIdentity() async throws -> MarfaAccountIdentity {
        let me = try await auth.me()
        return MarfaAccountIdentity(
            serverURL: configuration.url,
            spaceId: me.space.id
        )
    }

    /// Whether this client's store belongs to `identity`.
    ///
    /// Reads a recorded claim and compares. No network, and it never records
    /// anything — see ``claimStore(for:)`` for why those are separate.
    ///
    /// - Throws: ``NoLocalStoreError`` when this client has no store.
    public func storeOwnership(
        for identity: MarfaAccountIdentity
    ) async throws -> StoreOwnership {
        guard let localStore else {
            throw NoLocalStoreError(operation: "storeOwnership(for:)")
        }
        guard let claim = try await localStore.accountClaim() else {
            return .unclaimed
        }
        return claim == identity ? .sameAccount : .differentAccount
    }

    /// Resolve the account behind `credentialClient` and compare it to this
    /// client's store, in one step.
    ///
    /// A failure to resolve the account returns ``StoreOwnership/unresolved``
    /// rather than throwing, because that state is a real answer and callers
    /// must handle it deliberately: a wipe should treat it as "do nothing" and
    /// an upload must treat it as "stop". Errors reading the *store* are a
    /// different thing and are thrown.
    ///
    /// - Parameter credentialClient: A network-backed client built with the
    ///   incoming credential.
    /// - Throws: ``NoLocalStoreError``, or a store read failure.
    public func storeOwnership(
        resolvedWith credentialClient: MarfaClient
    ) async throws -> StoreOwnership {
        guard localStore != nil else {
            throw NoLocalStoreError(operation: "storeOwnership(resolvedWith:)")
        }
        let identity: MarfaAccountIdentity
        do {
            identity = try await credentialClient.accountIdentity()
        } catch {
            return .unresolved
        }
        return try await storeOwnership(for: identity)
    }

    /// Record that this store belongs to `identity`.
    ///
    /// Separate from asking, and deliberately so. Recording is a claim that the
    /// store now belongs to this account, and at the moment a caller *asks* the
    /// question that is not yet true — the upload it is deciding whether to run
    /// has not happened. A resolve that quietly recorded would make the second
    /// attempt after a failed upload read as ``StoreOwnership/sameAccount`` and
    /// skip the very check that protects it.
    ///
    /// Call it once the store and the account genuinely correspond.
    ///
    /// - Throws: ``NoLocalStoreError`` when this client has no store.
    public func claimStore(for identity: MarfaAccountIdentity) async throws {
        guard let localStore else {
            throw NoLocalStoreError(operation: "claimStore(for:)")
        }
        try await localStore.setAccountClaim(identity)
    }

    /// Forget which account this store belongs to.
    ///
    /// For a consumer that keeps a store across a sign-out and wants the next
    /// sign-in to be treated as a first one.
    ///
    /// - Throws: ``NoLocalStoreError`` when this client has no store.
    public func releaseStoreClaim() async throws {
        guard let localStore else {
            throw NoLocalStoreError(operation: "releaseStoreClaim()")
        }
        try await localStore.clearAccountClaim()
    }
}
