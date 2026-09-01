import Foundation

/// Ending a Marfa session, in one call.
///
/// Deliberately outside the `AuthenticationServices` guard that ``MarfaAuth``
/// carries. `MarfaAuth` does not exist on watchOS or tvOS, and ``DeviceFlow``
/// — which exists precisely for those platforms — writes the same storage
/// accounts. A sign-out that only compiled where the interactive flow compiles
/// would leave the constrained clients holding exactly the credentials this
/// type exists to give up.
///
/// ```swift
/// try await MarfaSession.end(
///     serverURL: URL(string: "https://api.marfa.so")!,
///     clientId: clientId,
///     storage: KeychainStorage(),
///     revoking: provider
/// )
/// ```
public enum MarfaSession {

    /// What actually happened, since half of it can fail without the rest
    /// failing with it.
    public enum EndResult: Sendable, Equatable, Hashable {
        /// The tokens were revoked with the server and the device is clear.
        case revokedAndCleared

        /// The device is clear and the server may still hold a live grant.
        ///
        /// Two ways to get here, and they are worth telling apart at the call
        /// site even though the local outcome is identical: no provider was
        /// passed, so there was no token to present for revocation; or
        /// revocation was attempted and did not succeed, typically because the
        /// device is offline or discovery is unreachable.
        ///
        /// Neither is a reason to leave credentials on the device, which is why
        /// this is a result rather than a thrown error. It is a reason to care:
        /// an unrevoked refresh token outlives the app that stopped holding it,
        /// and there is no admin route to clean one up afterwards.
        case clearedButNotRevoked
    }

    /// Give up every credential this SDK holds for a Marfa server, and revoke
    /// them with that server when a provider is supplied.
    ///
    /// This exists because ending a session correctly took two calls in the
    /// right order plus a value nobody could guess. ``MarfaAuth/signOut(_:)``
    /// revokes and clears the *tokens* account, and leaves the pending PKCE
    /// account and both pre-11.4.0 spellings behind;
    /// ``MarfaAuth/clearStoredCredentials(serverURL:clientId:storage:)`` reaches
    /// all four and revokes nothing. Doing one and not the other leaves either
    /// a credential on the device or a live grant on the server, and neither
    /// failure says anything at the time.
    ///
    /// - Important: This takes the **server URL**, not the issuer. That is the
    ///   difference between this and the call it replaces. A Marfa deployment
    ///   mounts its authorization server under `/auth` and publishes
    ///   `https://<host>/auth` as its issuer, storage accounts are keyed on
    ///   that derived value, and every consumer of this SDK reached for the
    ///   bare host instead. On sign-in that fails loudly; on a *clear* it
    ///   succeeds, deletes nothing, and leaves a working credential on a device
    ///   the person believes is signed out. Deriving it here means the wrong
    ///   value cannot be supplied.
    ///
    /// - Note: The registered OAuth client id is not a credential and is not
    ///   touched — the SDK never stores one, and a consumer should keep its
    ///   own. Discarding it makes the next sign-in register a fresh Dynamic
    ///   Client Registration client, and there is no admin route to remove one;
    ///   they accumulate, holding live refresh tokens.
    ///
    /// - Note: An API key saved with ``MarfaClient/saveToKeychain(service:account:accessGroup:)``
    ///   lives in a separate account namespace of the consumer's own choosing
    ///   and is not touched either. That is application state rather than
    ///   session state, and the SDK has no way to know which account name to
    ///   look under.
    ///
    /// - Parameters:
    ///   - serverURL: The Marfa server, e.g. `https://api.marfa.so`. The OAuth
    ///     issuer is derived from it.
    ///   - clientId: The OAuth client id the session was established under.
    ///     Credentials are keyed on it, so a session established under a
    ///     different client id is not reached by this call.
    ///   - storage: Where the credentials live.
    ///   - provider: The live provider, when there is one. Supply it to revoke
    ///     server-side. Omit it when there is nothing in hand — the offline
    ///     case, or a cold launch that never restored a session — and the local
    ///     clear still happens.
    ///   - urlSession: Session used for the revocation call.
    /// - Returns: Whether the server was told, as well as the device.
    /// - Throws: Only storage errors. A failed revocation is reported through
    ///   the result, because giving up local credentials must not depend on
    ///   reaching the network.
    @discardableResult
    public static func end(
        serverURL: URL,
        clientId: String,
        storage: any SecureStorage,
        revoking provider: (any TokenProvider)? = nil,
        urlSession: URLSession = .shared
    ) async throws -> EndResult {
        let issuer = OAuthDiscovery.derivedIssuer(forServer: serverURL)

        var revoked = false
        if let stored = provider as? StoredTokenProvider {
            // Best effort, and ordered so the local clear happens whatever this
            // does. The server may have revoked already, or the device may be
            // offline; neither is a reason to keep a credential here.
            do {
                let token = try await stored.currentToken()
                try await revokeToken(
                    token.accessToken,
                    issuer: issuer,
                    clientId: clientId,
                    urlSession: urlSession
                )
                if let refresh = token.refreshToken {
                    try await revokeToken(
                        refresh,
                        issuer: issuer,
                        clientId: clientId,
                        urlSession: urlSession
                    )
                }
                revoked = true
            } catch {
                revoked = false
            }
            // Clears the tokens account and drops the provider's in-memory
            // cache, which the storage sweep below cannot reach.
            try? await stored.clear()
        }

        try await clearCredentialAccounts(
            issuer: issuer,
            clientId: clientId,
            storage: storage
        )

        return revoked ? .revokedAndCleared : .clearedButNotRevoked
    }
}

// MARK: - Shared internals

/// Delete every spelling of every credential account for one issuer and client.
///
/// One implementation, reached from ``MarfaSession/end(serverURL:clientId:storage:revoking:urlSession:)``
/// and from ``MarfaAuth/clearStoredCredentials(serverURL:clientId:storage:)``. It
/// lives here rather than on `MarfaAuth` because `MarfaAuth` does not exist on
/// every platform that can hold these accounts.
///
/// Takes the already-derived issuer: the callers differ on where they get it,
/// and this is below that decision.
internal func clearCredentialAccounts(
    issuer: URL,
    clientId: String,
    storage: any SecureStorage
) async throws {
    let canonical = OAuthIssuer.normalize(issuer)
    for key in [
        OAuthIssuer.storageKey(kind: "tokens", issuer: canonical, clientId: clientId),
        OAuthIssuer.storageKey(kind: "pending", issuer: canonical, clientId: clientId),
        OAuthIssuer.legacyStorageKey(kind: "tokens", issuer: canonical, clientId: clientId),
        OAuthIssuer.legacyStorageKey(kind: "pending", issuer: canonical, clientId: clientId),
    ] {
        try await storage.delete(for: key)
    }
}

/// POST one token to the issuer's revocation endpoint (RFC 7009).
///
/// Shared with ``MarfaAuth`` so there is one description of what revoking a
/// token means, rather than a copy on each platform's entry point.
internal func revokeToken(
    _ token: String,
    issuer: URL,
    clientId: String,
    urlSession: URLSession
) async throws {
    let endpoints = try await OAuthDiscovery.shared.endpoints(
        for: issuer,
        httpClient: urlSession
    )
    var request = URLRequest(url: endpoints.revoke)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formURLEncode([
        "token": token,
        "client_id": clientId,
    ]).data(using: .utf8)
    _ = try await urlSession.data(for: request)
}
