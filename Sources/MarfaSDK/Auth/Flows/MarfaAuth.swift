#if canImport(AuthenticationServices) && !os(watchOS) && !os(tvOS)

import AuthenticationServices
import Foundation

/// `MarfaAuth` owns the Authorization-Code-with-PKCE flow against a Marfa
/// server's OAuth endpoints. URLs are discovered at first use via the
/// server's `/.well-known/oauth-authorization-server` doc — see
/// ``OAuthDiscovery``.
///
/// ## Flow
///
/// The server URL and the OAuth issuer identifier are **not the same value**.
/// A Marfa deployment publishes `https://<host>/auth` as its issuer, so keep
/// the server URL and derive the issuer from it with
/// ``OAuthDiscovery/issuer(forServer:)``. Passing the bare server URL here
/// fails at the first discovery call, and building a ``MarfaClient`` from
/// ``issuer`` points the API at `/auth`.
///
/// ```swift
/// let serverURL = URL(string: "https://api.marfa.so")!
///
/// let auth = MarfaAuth(
///     issuer: OAuthDiscovery.issuer(forServer: serverURL),
///     clientId: "marfa-notes",
///     redirectURI: URL(string: "marfa-notes://auth/callback")!,
///     scopes: ["core.note:read", "core.note:write", "openid", "profile", "email"],
///     storage: KeychainStorage()
/// )
///
/// // On a "Sign in" tap:
/// let provider = try await auth.signIn(presentationContextProvider: window)
/// let client = MarfaClient(url: serverURL, tokenProvider: provider)
///
/// // On app cold-start:
/// if let provider = try await auth.restore() {
///     let client = MarfaClient(url: serverURL, tokenProvider: provider)
/// }
///
/// // On sign-out:
/// try await auth.signOut(provider)
/// ```
///
/// ## Side effects
///
/// - ``signIn(presentationContextProvider:)`` opens an
///   `ASWebAuthenticationSession` that takes the user through the
///   server's consent screen, then exchanges the returned code at the
///   discovered token endpoint with the PKCE verifier. The token bundle
///   is persisted via the configured ``SecureStorage``.
/// - ``restore()`` reads any persisted token from storage and returns a
///   ``StoredTokenProvider`` ready to use; returns `nil` if storage is
///   empty.
/// - ``signOut(_:)`` POSTs to the discovered revocation endpoint and
///   clears the persisted token. Surface-level "session expired" UX is
///   the caller's responsibility.
///
/// Available on iOS, macOS, Mac Catalyst, and visionOS — `ASWebAuthenticationSession`
/// is not exposed on watchOS or tvOS, where ``DeviceFlow`` is the
/// appropriate alternative.
///
/// Isolated to `@MainActor` because every operation either drives a UI
/// session or coordinates with one. Token persistence still funnels
/// through the injected ``SecureStorage`` actor; the main-actor isolation
/// here only governs the flow's own state.
@MainActor
public final class MarfaAuth {

    /// The OAuth issuer identifier, as the caller spelled it.
    ///
    /// Not the API base URL, and not a substitute for it. On a Marfa
    /// deployment the two differ by a `/auth` path component — see
    /// ``OAuthDiscovery/issuer(forServer:)`` — so a ``MarfaClient`` built from
    /// this addresses `/auth` rather than the API.
    ///
    /// Discovery compares the published `issuer` against this, not against the
    /// canonical form: an identifier that legitimately ends in a slash is the
    /// server's to declare, and normalizing before the comparison made every
    /// such provider unusable — the flow had already dropped the slash, so the
    /// document could never match. Canonicalization belongs to storage keys,
    /// where it stops two spellings of one issuer owning separate credentials.
    public let issuer: URL

    /// The canonical form, used for storage keys only.
    private let canonicalIssuer: URL
    public let clientId: String
    public let redirectURI: URL
    public let scopes: [String]

    private let storage: any SecureStorage
    private let urlSession: URLSession
    private let pendingKey: String
    private let tokensKey: String

    public init(
        issuer: URL,
        clientId: String,
        redirectURI: URL,
        scopes: [String],
        storage: any SecureStorage,
        urlSession: URLSession = .shared
    ) {
        self.issuer = issuer
        self.canonicalIssuer = OAuthIssuer.normalize(issuer)
        self.clientId = clientId
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.storage = storage
        self.urlSession = urlSession
        self.pendingKey = OAuthIssuer.storageKey(
            kind: "pending",
            issuer: self.canonicalIssuer,
            clientId: clientId
        )
        self.tokensKey = OAuthIssuer.storageKey(
            kind: "tokens",
            issuer: self.canonicalIssuer,
            clientId: clientId
        )
    }

    /// Drives the full Authorization Code + PKCE flow and returns a
    /// ``TokenProvider`` ready to use with ``MarfaClient``.
    ///
    /// Steps:
    /// 1. Generate PKCE verifier and S256 challenge.
    /// 2. Discover the `authorization_endpoint` and open
    ///    `ASWebAuthenticationSession` against it with the challenge.
    /// 3. On callback, validate `state`, then POST the code to the
    ///    discovered `token_endpoint` with the verifier.
    /// 4. Persist the resulting ``Token`` via ``StoredTokenProvider``.
    public func signIn(
        presentationContextProvider: ASWebAuthenticationPresentationContextProviding
    ) async throws -> TokenProvider {
        _ = try OAuthIssuer.canonicalURL(issuer)
        let verifier = PKCE.generateCodeVerifier()
        let challenge = PKCE.computeCodeChallenge(verifier: verifier)
        let state = PKCE.generateState()

        let pending = PendingState(
            verifier: verifier,
            state: state,
            redirectURI: redirectURI.absoluteString
        )
        try await persist(pending)

        let endpoints = try await OAuthDiscovery.shared.endpoints(
            for: issuer,
            httpClient: urlSession
        )
        let authorizeURL = try buildAuthorizeURL(
            authorize: endpoints.authorize,
            challenge: challenge,
            state: state
        )
        let callbackURL = try await runWebAuthSession(
            authorizeURL: authorizeURL,
            presentationContextProvider: presentationContextProvider
        )

        let (code, returnedState) = try parseCallback(callbackURL)
        guard returnedState == state else {
            throw OAuthError(rawCode: "invalid_state", message: "state parameter mismatch", status: 400)
        }

        let token = try await exchangeCode(
            code: code,
            verifier: verifier,
            tokenEndpoint: endpoints.token
        )
        let provider = StoredTokenProvider(
            storage: storage,
            storageKey: tokensKey,
            tokenEndpoint: endpoints.token,
            clientId: clientId,
            urlSession: urlSession
        )
        try await provider.store(token)
        try await storage.delete(for: pendingKey)
        return provider
    }

    /// Returns a ``TokenProvider`` backed by any token already persisted
    /// for this `(issuer, clientId)` pair, or `nil` when storage is empty.
    public func restore() async throws -> TokenProvider? {
        _ = try OAuthIssuer.canonicalURL(issuer)
        _ = try await OAuthIssuer.migrateLegacyRootTokenIfNeeded(
            in: storage,
            issuer: issuer,
            clientId: clientId
        )
        guard try await storage.get(for: tokensKey) != nil else { return nil }
        let endpoints = try await OAuthDiscovery.shared.endpoints(
            for: issuer,
            httpClient: urlSession
        )
        return StoredTokenProvider(
            storage: storage,
            storageKey: tokensKey,
            tokenEndpoint: endpoints.token,
            clientId: clientId,
            urlSession: urlSession
        )
    }

    /// Revokes the access and refresh tokens with the server, then clears
    /// the persisted bundle. The provider is unusable after this call;
    /// callers should drop their reference and rebuild the client when
    /// the user signs in again.
    /// Remove every credential this SDK stores for one issuer and client,
    /// without needing a token provider.
    ///
    /// The path taken when discovery is unreachable, so ``restore()`` cannot
    /// build a provider and ``signOut(_:)`` has nothing to act on — and the
    /// only correct way for a consumer to clear that state.
    ///
    /// It exists because the alternative is a consumer rebuilding the storage
    /// key by hand. `OAuthIssuer` is internal, so a hand-built key can only be
    /// the spelling that happened to be right when it was written, and this
    /// SDK has changed that spelling: `marfa.auth.tokens.v2:<len>:<issuer>:` —
    /// with a length prefix, so no two issuers can produce one key — replaced
    /// `marfa.auth.tokens:<host>:`. An app still deleting the old one deletes
    /// a row the SDK's own migration has already emptied, reports success, and
    /// leaves a working credential on a device the user believes is signed
    /// out. Nothing fails, which is what makes it worth a supported call.
    ///
    /// Clears the legacy spelling too, so an install that never restored a
    /// session after upgrading is covered as well.
    ///
    /// - Note: This clears and does not revoke, so on its own it leaves a live
    ///   grant on the server. Unless you specifically want only the local half,
    ///   prefer ``MarfaSession/end(serverURL:clientId:storage:revoking:urlSession:)``,
    ///   which does both, takes the server URL so the issuer cannot be got
    ///   wrong, and works on the platforms this type does not exist on.
    public static func clearStoredCredentials(
        issuer: URL,
        clientId: String,
        storage: any SecureStorage
    ) async throws {
        // One implementation, in `MarfaSession.swift`, because this is reachable
        // on platforms where `MarfaAuth` is not.
        try await clearCredentialAccounts(
            issuer: issuer,
            clientId: clientId,
            storage: storage
        )
    }

    /// Revoke this session's tokens with the server and forget them locally.
    ///
    /// Does less than the name suggests, which is worth knowing before relying
    /// on it as a sign-out:
    ///
    /// - It is a **no-op for any provider that is not a `StoredTokenProvider`**,
    ///   so an API-key session passes through it unchanged.
    /// - It clears only the **tokens** account. The pending PKCE account and
    ///   both pre-11.4.0 spellings are left in storage.
    /// - It needs a live provider, which needs discovery to have succeeded, so
    ///   it cannot help on a device that is offline.
    ///
    /// For ending a session, prefer
    /// ``MarfaSession/end(serverURL:clientId:storage:revoking:urlSession:)``,
    /// which composes this with the full storage sweep in the right order and
    /// still clears when there is no provider to revoke with.
    public func signOut(_ provider: TokenProvider) async throws {
        if let stored = provider as? StoredTokenProvider {
            do {
                let token = try await stored.currentToken()
                try await revoke(token: token.accessToken)
                if let refresh = token.refreshToken {
                    try await revoke(token: refresh)
                }
            } catch {
                // Server may already have revoked, network may be down —
                // either way, clear local state so the next sign-in is
                // clean.
            }
            try await stored.clear()
        }
    }

    // MARK: - Internals

    // The seams below are `internal` rather than `private` so the test
    // module can exercise them via `@testable import MarfaSDK` without
    // standing up the full `ASWebAuthenticationSession` flow. They are
    // not part of the public surface.

    /// Resolves the OAuth endpoints via discovery. Exposed for tests so
    /// they can stub the well-known doc once and exercise the flow.
    internal func discoveredEndpoints() async throws -> OAuthDiscovery.Endpoints {
        try await OAuthDiscovery.shared.endpoints(
            for: issuer,
            httpClient: urlSession
        )
    }

    private func persist(_ pending: PendingState) async throws {
        let data = try JSONEncoder().encode(pending)
        guard let json = String(data: data, encoding: .utf8) else {
            throw OAuthError(rawCode: "encoding_failed", message: "could not encode pending state", status: 500)
        }
        try await storage.set(json, for: pendingKey)
    }

    /// Test seam for asserting that PKCE state uses the same issuer identity
    /// isolation as stored tokens. Not part of the public API.
    internal func persistPendingForTesting(
        verifier: String,
        state: String
    ) async throws {
        _ = try OAuthIssuer.canonicalURL(issuer)
        try await persist(PendingState(
            verifier: verifier,
            state: state,
            redirectURI: redirectURI.absoluteString
        ))
    }

    internal func buildAuthorizeURL(
        authorize: URL,
        challenge: String,
        state: String
    ) throws -> URL {
        var components = URLComponents(url: authorize, resolvingAgainstBaseURL: false)
        guard components != nil else {
            throw OAuthError(rawCode: "invalid_issuer", message: "could not construct authorize URL", status: 400)
        }
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else {
            throw OAuthError(rawCode: "invalid_issuer", message: "could not construct authorize URL", status: 400)
        }
        return url
    }

    private func runWebAuthSession(
        authorizeURL: URL,
        presentationContextProvider: ASWebAuthenticationPresentationContextProviding
    ) async throws -> URL {
        let scheme = redirectURI.scheme
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: scheme
            ) { callbackURL, error in
                if let error = error {
                    if let asError = error as? ASWebAuthenticationSessionError,
                       asError.code == .canceledLogin {
                        continuation.resume(throwing: OAuthError(
                            rawCode: "user_cancelled",
                            message: "sign-in cancelled",
                            status: 400
                        ))
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL = callbackURL else {
                    continuation.resume(throwing: OAuthError(
                        rawCode: "invalid_response",
                        message: "no callback URL",
                        status: 400
                    ))
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = presentationContextProvider
            // Ephemeral browser session per Apple's OAuth-client guidance:
            // each sign-in starts with a fresh cookie jar, so the user's
            // IdP session ends when the OAuth flow completes. Without this
            // the better-auth session cookie persists in Safari and
            // `signOut(_:)` only clears the SDK-side token — the next
            // sign-in skips the password prompt because the IdP still
            // recognizes the cookie. Ephemeral is the secure default for
            // OAuth public clients.
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }
    }

    internal func parseCallback(_ url: URL) throws -> (code: String, state: String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OAuthError(rawCode: "invalid_callback", message: "could not parse callback URL", status: 400)
        }
        if let errorCode = components.queryItems?.first(where: { $0.name == "error" })?.value {
            let description = components.queryItems?
                .first(where: { $0.name == "error_description" })?.value
            throw OAuthError(rawCode: errorCode, message: description ?? errorCode, status: 400)
        }
        guard
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
            let state = components.queryItems?.first(where: { $0.name == "state" })?.value
        else {
            throw OAuthError(rawCode: "invalid_callback", message: "missing code or state", status: 400)
        }
        return (code, state)
    }

    internal func exchangeCode(
        code: String,
        verifier: String,
        tokenEndpoint: URL
    ) async throws -> Token {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "client_id": clientId,
            "code_verifier": verifier,
        ]
        request.httpBody = formURLEncode(body).data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError(rawCode: "invalid_response", message: "no HTTP response", status: 500)
        }
        if !(200..<300).contains(http.statusCode) {
            throw try parseOAuthError(data: data, status: http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Token.self, from: data)
    }

    internal func revoke(token: String) async throws {
        try await revokeToken(
            token,
            issuer: issuer,
            clientId: clientId,
            urlSession: urlSession
        )
    }

    private struct PendingState: Codable {
        let verifier: String
        let state: String
        let redirectURI: String
    }
}

#endif
