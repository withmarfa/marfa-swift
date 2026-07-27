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
/// ```swift
/// let auth = MarfaAuth(
///     issuer: URL(string: "https://staging.marfa.so")!,
///     clientId: "marfa-notes",
///     redirectURI: URL(string: "marfa-notes://auth/callback")!,
///     scopes: ["core.note:read", "core.note:write", "openid", "profile", "email"],
///     storage: KeychainStorage()
/// )
///
/// // On a "Sign in" tap:
/// let provider = try await auth.signIn(presentationContextProvider: window)
/// let client = MarfaClient(url: auth.issuer, tokenProvider: provider)
///
/// // On app cold-start:
/// if let provider = try await auth.restore() {
///     let client = MarfaClient(url: auth.issuer, tokenProvider: provider)
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

    public let issuer: URL
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
        self.issuer = OAuthIssuer.normalize(issuer)
        self.clientId = clientId
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.storage = storage
        self.urlSession = urlSession
        self.pendingKey = OAuthIssuer.storageKey(
            kind: "pending",
            issuer: self.issuer,
            clientId: clientId
        )
        self.tokensKey = OAuthIssuer.storageKey(
            kind: "tokens",
            issuer: self.issuer,
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
        let endpoints = try await OAuthDiscovery.shared.endpoints(
            for: issuer,
            httpClient: urlSession
        )
        var request = URLRequest(url: endpoints.revoke)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "token": token,
            "client_id": clientId,
        ]
        request.httpBody = formURLEncode(body).data(using: .utf8)
        _ = try await urlSession.data(for: request)
    }

    private struct PendingState: Codable {
        let verifier: String
        let state: String
        let redirectURI: String
    }
}

#endif
