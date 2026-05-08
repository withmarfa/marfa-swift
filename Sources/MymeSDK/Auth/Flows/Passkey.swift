#if canImport(AuthenticationServices)

import AuthenticationServices
import Foundation

/// Passkey (WebAuthn) registration and authentication backed by the
/// platform's `ASAuthorizationPlatformPublicKeyCredentialProvider` and
/// the server's Better-Auth-style `/auth/passkey/*` endpoints.
///
/// ## Server contract
///
/// The SDK targets the SimpleWebAuthn payload shape (the wire format
/// Better-Auth ships). Endpoints used:
///
/// - `POST /auth/passkey/generate-register-options`
/// - `POST /auth/passkey/verify-register`
/// - `POST /auth/passkey/generate-authentication-options`
/// - `POST /auth/passkey/verify-authentication`
///
/// Some Better-Auth deployments mount the auth router under `/api/auth`
/// instead of `/auth`. Pass a custom `basePath` to ``register(...)`` /
/// ``authenticate(...)`` to override.
///
/// ## Platform support
///
/// Passkeys require iOS 18+/macOS 15+/watchOS 11+/tvOS 18+/visionOS 2+.
/// The SDK enforces these floors via the package's deployment targets.
///
/// All entry points are `@MainActor`-isolated because the underlying
/// `ASAuthorizationController` flow drives a system sheet and consumes a
/// non-Sendable presentation-context provider. Token persistence runs
/// off-actor via the injected ``SecureStorage``.
@MainActor
public enum Passkey {

    /// Default Better-Auth path prefix; override via the `basePath`
    /// parameter on ``register(...)`` / ``authenticate(...)`` if your
    /// deployment mounts the auth router elsewhere (e.g. `/api/auth`).
    public static let defaultBasePath = "/auth"

    /// Registers a new passkey for the calling user against the server's
    /// `/auth/passkey/verify-register` endpoint. The user is currently
    /// authenticated via some other flow (e.g. ``MymeAuth``) — the
    /// `tokenProvider` argument supplies the bearer that authorises the
    /// register call.
    public static func register(
        rpId: String,
        userName: String,
        userDisplayName: String,
        issuer: URL,
        tokenProvider: TokenProvider,
        basePath: String = defaultBasePath,
        presentationContextProvider: ASAuthorizationControllerPresentationContextProviding,
        urlSession: URLSession = .shared
    ) async throws {
        let issuerURL = normalizeIssuer(issuer)
        let token = try await tokenProvider.currentToken()

        let options = try await generateRegisterOptions(
            issuer: issuerURL,
            basePath: basePath,
            token: token,
            urlSession: urlSession
        )

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: rpId
        )
        let request = provider.createCredentialRegistrationRequest(
            challenge: options.challenge,
            name: userName,
            userID: options.userId
        )
        request.displayName = userDisplayName

        let credential = try await runController(
            request: request,
            presentationContextProvider: presentationContextProvider
        )
        guard let registration = credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw PasskeyError(
                rawCode: "verification_failed",
                message: "unexpected credential type from authorization controller"
            )
        }

        try await verifyRegister(
            issuer: issuerURL,
            basePath: basePath,
            token: token,
            registration: registration,
            urlSession: urlSession
        )
    }

    /// Authenticates the user via an existing passkey and returns a
    /// ``TokenProvider`` ready to wire into ``MymeClient``.
    public static func authenticate(
        rpId: String,
        issuer: URL,
        clientId: String,
        storage: any SecureStorage,
        basePath: String = defaultBasePath,
        presentationContextProvider: ASAuthorizationControllerPresentationContextProviding,
        urlSession: URLSession = .shared
    ) async throws -> TokenProvider {
        let issuerURL = normalizeIssuer(issuer)
        let options = try await generateAuthenticationOptions(
            issuer: issuerURL,
            basePath: basePath,
            urlSession: urlSession
        )

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: rpId
        )
        let request = provider.createCredentialAssertionRequest(challenge: options.challenge)

        let credential = try await runController(
            request: request,
            presentationContextProvider: presentationContextProvider
        )
        guard let assertion = credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw PasskeyError(
                rawCode: "verification_failed",
                message: "unexpected credential type from authorization controller"
            )
        }

        let token = try await verifyAuthentication(
            issuer: issuerURL,
            basePath: basePath,
            assertion: assertion,
            urlSession: urlSession
        )

        let storageKey = "myme.auth.tokens:\(issuerURL.host ?? issuerURL.absoluteString):\(clientId)"
        let stored = StoredTokenProvider(
            storage: storage,
            storageKey: storageKey,
            tokenEndpoint: issuerURL.appendingPathComponent("auth/token"),
            clientId: clientId,
            urlSession: urlSession
        )
        try await stored.store(token)
        return stored
    }

    // MARK: - Server calls

    private static func generateRegisterOptions(
        issuer: URL,
        basePath: String,
        token: Token,
        urlSession: URLSession
    ) async throws -> RegisterOptions {
        var request = URLRequest(url: issuer.appendingPathComponent("\(basePath)/passkey/generate-register-options"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        try ensureOK(response: response, data: data, label: "generate-register-options")

        let envelope = try JSONDecoder().decode(RegisterOptionsEnvelope.self, from: data)
        guard
            let challenge = base64URLDecode(envelope.challenge),
            let userId = base64URLDecode(envelope.user.id)
        else {
            throw PasskeyError(rawCode: "verification_failed", message: "could not decode register options")
        }
        return RegisterOptions(challenge: challenge, userId: userId)
    }

    private static func verifyRegister(
        issuer: URL,
        basePath: String,
        token: Token,
        registration: ASAuthorizationPlatformPublicKeyCredentialRegistration,
        urlSession: URLSession
    ) async throws {
        let payload = RegisterVerifyPayload(
            id: base64URLEncode(registration.credentialID),
            rawId: base64URLEncode(registration.credentialID),
            type: "public-key",
            response: RegisterVerifyPayload.Response(
                attestationObject: base64URLEncode(registration.rawAttestationObject ?? Data()),
                clientDataJSON: base64URLEncode(registration.rawClientDataJSON)
            ),
            clientExtensionResults: [:]
        )

        var request = URLRequest(url: issuer.appendingPathComponent("\(basePath)/passkey/verify-register"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await urlSession.data(for: request)
        try ensureOK(response: response, data: data, label: "verify-register")
    }

    private static func generateAuthenticationOptions(
        issuer: URL,
        basePath: String,
        urlSession: URLSession
    ) async throws -> AuthenticationOptions {
        var request = URLRequest(url: issuer.appendingPathComponent("\(basePath)/passkey/generate-authentication-options"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        try ensureOK(response: response, data: data, label: "generate-authentication-options")

        let envelope = try JSONDecoder().decode(AuthenticationOptionsEnvelope.self, from: data)
        guard let challenge = base64URLDecode(envelope.challenge) else {
            throw PasskeyError(rawCode: "verification_failed", message: "could not decode authentication challenge")
        }
        return AuthenticationOptions(challenge: challenge)
    }

    private static func verifyAuthentication(
        issuer: URL,
        basePath: String,
        assertion: ASAuthorizationPlatformPublicKeyCredentialAssertion,
        urlSession: URLSession
    ) async throws -> Token {
        let payload = AuthenticationVerifyPayload(
            id: base64URLEncode(assertion.credentialID),
            rawId: base64URLEncode(assertion.credentialID),
            type: "public-key",
            response: AuthenticationVerifyPayload.Response(
                authenticatorData: base64URLEncode(assertion.rawAuthenticatorData),
                clientDataJSON: base64URLEncode(assertion.rawClientDataJSON),
                signature: base64URLEncode(assertion.signature),
                userHandle: assertion.userID.map(base64URLEncode)
            ),
            clientExtensionResults: [:]
        )

        var request = URLRequest(url: issuer.appendingPathComponent("\(basePath)/passkey/verify-authentication"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await urlSession.data(for: request)
        try ensureOK(response: response, data: data, label: "verify-authentication")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Token.self, from: data)
    }

    // MARK: - ASAuthorizationController bridge

    @MainActor
    private static func runController(
        request: ASAuthorizationRequest,
        presentationContextProvider: ASAuthorizationControllerPresentationContextProviding
    ) async throws -> ASAuthorizationCredential {
        let bridge = PasskeyControllerBridge(presentationContextProvider: presentationContextProvider)
        return try await bridge.perform(request: request)
    }

    // MARK: - Helpers

    private static func normalizeIssuer(_ url: URL) -> URL {
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s) ?? url
    }

    private static func ensureOK(response: URLResponse, data: Data, label: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PasskeyError(rawCode: "invalid_response", message: "no HTTP response from \(label)")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw PasskeyError(
                rawCode: "verification_failed",
                message: "\(label) failed: \(body)",
                details: nil
            )
        }
    }

    fileprivate static func base64URLDecode(_ s: String) -> Data? {
        var padded = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        return Data(base64Encoded: padded)
    }

    fileprivate static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Wire payloads

    private struct RegisterOptionsEnvelope: Decodable {
        let challenge: String
        let user: User
        struct User: Decodable {
            let id: String
        }
    }

    private struct RegisterOptions {
        let challenge: Data
        let userId: Data
    }

    private struct RegisterVerifyPayload: Encodable {
        let id: String
        let rawId: String
        let type: String
        let response: Response
        let clientExtensionResults: [String: String]

        struct Response: Encodable {
            let attestationObject: String
            let clientDataJSON: String
        }
    }

    private struct AuthenticationOptionsEnvelope: Decodable {
        let challenge: String
    }

    private struct AuthenticationOptions {
        let challenge: Data
    }

    private struct AuthenticationVerifyPayload: Encodable {
        let id: String
        let rawId: String
        let type: String
        let response: Response
        let clientExtensionResults: [String: String]

        struct Response: Encodable {
            let authenticatorData: String
            let clientDataJSON: String
            let signature: String
            let userHandle: String?
        }
    }
}

/// Bridge between `ASAuthorizationController`'s delegate API and async/await.
@MainActor
private final class PasskeyControllerBridge: NSObject, ASAuthorizationControllerDelegate {
    private weak var presentationContextProvider: ASAuthorizationControllerPresentationContextProviding?
    private var continuation: CheckedContinuation<ASAuthorizationCredential, Error>?

    init(presentationContextProvider: ASAuthorizationControllerPresentationContextProviding) {
        self.presentationContextProvider = presentationContextProvider
    }

    func perform(request: ASAuthorizationRequest) async throws -> ASAuthorizationCredential {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ASAuthorizationCredential, Error>) in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self.presentationContextProvider
            controller.performRequests()
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            self.continuation?.resume(returning: authorization.credential)
            self.continuation = nil
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            if let asError = error as? ASAuthorizationError, asError.code == .canceled {
                self.continuation?.resume(throwing: PasskeyError(
                    rawCode: "user_cancelled",
                    message: "passkey flow cancelled"
                ))
            } else {
                self.continuation?.resume(throwing: PasskeyError(
                    rawCode: "verification_failed",
                    message: error.localizedDescription
                ))
            }
            self.continuation = nil
        }
    }
}

#endif
