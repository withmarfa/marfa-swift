import Foundation

/// Device Authorization Grant (RFC 8628) flow for headless or
/// constrained-input clients (TVs, watches, CLI tools).
///
/// ## Flow
///
/// ```swift
/// let handle = try await DeviceFlow.start(
///     issuer: URL(string: "https://staging.marfa.so")!,
///     clientId: "marfa-cli",
///     scopes: ["core.note:read"],
///     storage: KeychainStorage()
/// )
///
/// // Show the user the verification info:
/// print("Visit \(handle.verificationURI) and enter \(handle.userCode)")
/// if let complete = handle.verificationURIComplete {
///     // Or open the all-in-one URL on a connected device:
///     UIApplication.shared.open(complete)
/// }
///
/// // Block on the user finishing:
/// let provider = try await handle.awaitToken()
/// let client = MarfaClient(url: handle.issuer, tokenProvider: provider)
/// ```
public enum DeviceFlow {

    /// Starts a device authorization request against the server's
    /// `/auth/device` endpoint. The returned ``DeviceFlowHandle``
    /// carries the user-facing codes and an ``DeviceFlowHandle/awaitToken()``
    /// method that polls until the user completes verification (or the
    /// code expires).
    ///
    /// - Parameters:
    ///   - httpClient: HTTP transport seam — defaults to
    ///     `URLSession.shared`. Tests inject a fake; consumer apps
    ///     normally leave the default.
    ///   - clock: Time seam — defaults to ``SystemDeviceFlowClock``.
    ///     Used for the device-code expiry timestamp on the returned
    ///     handle and the between-poll sleep inside `awaitToken()`.
    public static func start(
        issuer: URL,
        clientId: String,
        scopes: [String],
        storage: any SecureStorage,
        httpClient: any DeviceFlowHTTPClient = URLSession.shared,
        clock: any DeviceFlowClock = SystemDeviceFlowClock()
    ) async throws -> DeviceFlowHandle {
        // Validated, not substituted. Discovery compares the published
        // `issuer` against what the caller asked for, so handing it the
        // canonical form made a server whose identifier legitimately ends in a
        // slash impossible to reach: the slash had already been dropped, and
        // the document could never match. Canonicalization is for storage
        // keys, further down.
        let canonicalIssuer = try OAuthIssuer.canonicalURL(issuer)
        let endpoints = try await OAuthDiscovery.shared.endpoints(
            for: issuer,
            httpClient: httpClient
        )
        var request = URLRequest(url: endpoints.deviceAuthorize)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "client_id": clientId,
            "scope": scopes.joined(separator: " "),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError(rawCode: "invalid_response", message: "no HTTP response", status: 500)
        }
        if !(200..<300).contains(http.statusCode) {
            throw try parseOAuthError(data: data, status: http.statusCode)
        }

        let envelope = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        // Force-unwrapping a server-supplied string would crash the app on a
        // malformed response, which is a server's mistake to make and not a
        // reason to trap. The safe form is already used one line below for the
        // optional sibling.
        guard let verificationURI = URL(string: envelope.verificationURI) else {
            throw DeviceFlowError(
                rawCode: "invalid_response",
                message: "verification_uri is not a URL: \(envelope.verificationURI)"
            )
        }
        return DeviceFlowHandle(
            issuer: canonicalIssuer,
            clientId: clientId,
            deviceCode: envelope.deviceCode,
            userCode: envelope.userCode,
            verificationURI: verificationURI,
            verificationURIComplete: envelope.verificationURIComplete.flatMap(URL.init(string:)),
            expiresAt: clock.now().addingTimeInterval(TimeInterval(envelope.expiresIn)),
            interval: envelope.interval ?? 5,
            endpoints: endpoints,
            storage: storage,
            httpClient: httpClient,
            clock: clock
        )
    }

    private struct DeviceCodeResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let verificationURIComplete: String?
        let expiresIn: Int
        let interval: Int?

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case verificationURIComplete = "verification_uri_complete"
            case expiresIn = "expires_in"
            case interval
        }
    }
}

/// Live handle returned by ``DeviceFlow/start(issuer:clientId:scopes:storage:httpClient:clock:)``.
///
/// The user-visible codes (``userCode``, ``verificationURI``,
/// ``verificationURIComplete``) are read-only. ``awaitToken()`` performs
/// the RFC 8628 polling loop and returns a ready-to-use
/// ``TokenProvider`` once the user completes verification.
public actor DeviceFlowHandle {

    public nonisolated let issuer: URL
    public nonisolated let clientId: String
    public nonisolated let userCode: String
    public nonisolated let verificationURI: URL
    public nonisolated let verificationURIComplete: URL?
    public nonisolated let expiresAt: Date

    private let deviceCode: String
    private var interval: Int
    private let endpoints: OAuthDiscovery.Endpoints
    private let storage: any SecureStorage
    private let httpClient: any DeviceFlowHTTPClient
    private let clock: any DeviceFlowClock

    init(
        issuer: URL,
        clientId: String,
        deviceCode: String,
        userCode: String,
        verificationURI: URL,
        verificationURIComplete: URL?,
        expiresAt: Date,
        interval: Int,
        endpoints: OAuthDiscovery.Endpoints,
        storage: any SecureStorage,
        httpClient: any DeviceFlowHTTPClient,
        clock: any DeviceFlowClock
    ) {
        self.issuer = issuer
        self.clientId = clientId
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresAt = expiresAt
        self.interval = interval
        self.endpoints = endpoints
        self.storage = storage
        self.httpClient = httpClient
        self.clock = clock
    }

    /// Polls `/auth/device/token` per RFC 8628 §3.4 until the user
    /// completes the verification step or the device code expires.
    ///
    /// - Returns: A ``StoredTokenProvider`` seeded with the granted
    ///   ``Token``, ready to wire into ``MarfaClient``.
    /// - Throws: ``DeviceFlowError`` for terminal device-flow errors
    ///   (``DeviceFlowError/Code/accessDenied``,
    ///   ``DeviceFlowError/Code/expiredToken``); ``OAuthError`` for
    ///   protocol-level failures.
    public func awaitToken() async throws -> TokenProvider {
        while true {
            if clock.now() >= expiresAt {
                throw DeviceFlowError(rawCode: "expired_token", message: "device code expired")
            }
            try await clock.sleep(for: TimeInterval(interval))

            let result = try await poll()
            switch result {
            case .pending:
                continue
            case .slowDown:
                interval += 5
                continue
            case .granted(let token):
                let storageKey = OAuthIssuer.storageKey(
                    kind: "tokens",
                    issuer: issuer,
                    clientId: clientId
                )
                let provider = StoredTokenProvider(
                    storage: storage,
                    storageKey: storageKey,
                    tokenEndpoint: endpoints.token,
                    clientId: clientId
                )
                try await provider.store(token)
                return provider
            }
        }
    }

    private enum PollResult {
        case pending
        case slowDown
        case granted(Token)
    }

    private func poll() async throws -> PollResult {
        // RFC 8628 polling endpoint — discovery publishes the device
        // authorize URL; the polling URL is the same path with `/token`
        // appended per Better Auth's convention.
        var request = URLRequest(
            url: endpoints.deviceAuthorize.appendingPathComponent("token")
        )
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": deviceCode,
            "client_id": clientId,
        ]
        request.httpBody = formURLEncode(body).data(using: .utf8)

        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError(rawCode: "invalid_response", message: "no HTTP response", status: 500)
        }
        if (200..<300).contains(http.statusCode) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let token = try decoder.decode(Token.self, from: data)
            return .granted(token)
        }

        let oauthError = try parseOAuthError(data: data, status: http.statusCode)
        switch DeviceFlowError.Code(rawValue: oauthError.code) {
        case .authorizationPending:
            return .pending
        case .slowDown:
            return .slowDown
        case .accessDenied:
            throw DeviceFlowError(rawCode: "access_denied", message: "user denied authorization")
        case .expiredToken:
            throw DeviceFlowError(rawCode: "expired_token", message: "device code expired")
        default:
            throw oauthError
        }
    }
}
