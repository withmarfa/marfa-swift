import Foundation

/// Device Authorization Grant (RFC 8628) flow for headless or
/// constrained-input clients (TVs, watches, CLI tools).
///
/// ## Flow
///
/// ```swift
/// let handle = try await DeviceFlow.start(
///     issuer: URL(string: "https://staging.myme.so")!,
///     clientId: "myme-cli",
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
/// let client = MymeClient(url: handle.issuer, tokenProvider: provider)
/// ```
public enum DeviceFlow {

    /// Starts a device authorization request against the server's
    /// `/auth/device` endpoint. The returned ``DeviceFlowHandle``
    /// carries the user-facing codes and an ``DeviceFlowHandle/awaitToken()``
    /// method that polls until the user completes verification (or the
    /// code expires).
    public static func start(
        issuer: URL,
        clientId: String,
        scopes: [String],
        storage: any SecureStorage,
        urlSession: URLSession = .shared
    ) async throws -> DeviceFlowHandle {
        let normalized = DeviceFlow.normalizeIssuer(issuer)
        var request = URLRequest(url: normalized.appendingPathComponent("auth/device"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = [
            "client_id": clientId,
            "scope": scopes.joined(separator: " "),
        ]
        request.httpBody = formURLEncode(body).data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError(rawCode: "invalid_response", message: "no HTTP response", status: 500)
        }
        if !(200..<300).contains(http.statusCode) {
            throw try parseOAuthError(data: data, status: http.statusCode)
        }

        let envelope = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        return DeviceFlowHandle(
            issuer: normalized,
            clientId: clientId,
            deviceCode: envelope.deviceCode,
            userCode: envelope.userCode,
            verificationURI: URL(string: envelope.verificationURI)!,
            verificationURIComplete: envelope.verificationURIComplete.flatMap(URL.init(string:)),
            expiresAt: Date().addingTimeInterval(TimeInterval(envelope.expiresIn)),
            interval: envelope.interval ?? 5,
            storage: storage,
            urlSession: urlSession
        )
    }

    private static func normalizeIssuer(_ url: URL) -> URL {
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s) ?? url
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

/// Live handle returned by ``DeviceFlow/start(issuer:clientId:scopes:storage:urlSession:)``.
///
/// The user-visible codes (``userCode``, ``verificationURI``,
/// ``verificationURIComplete``) are read-only. ``awaitToken()`` performs
/// the RFC 8628 polling loop and returns a ready-to-use
/// ``TokenProvider`` once the user completes verification.
public actor DeviceFlowHandle {

    public let issuer: URL
    public let clientId: String
    public let userCode: String
    public let verificationURI: URL
    public let verificationURIComplete: URL?
    public let expiresAt: Date

    private let deviceCode: String
    private var interval: Int
    private let storage: any SecureStorage
    private let urlSession: URLSession

    init(
        issuer: URL,
        clientId: String,
        deviceCode: String,
        userCode: String,
        verificationURI: URL,
        verificationURIComplete: URL?,
        expiresAt: Date,
        interval: Int,
        storage: any SecureStorage,
        urlSession: URLSession
    ) {
        self.issuer = issuer
        self.clientId = clientId
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresAt = expiresAt
        self.interval = interval
        self.storage = storage
        self.urlSession = urlSession
    }

    /// Polls `/auth/device/token` per RFC 8628 §3.4 until the user
    /// completes the verification step or the device code expires.
    ///
    /// - Returns: A ``StoredTokenProvider`` seeded with the granted
    ///   ``Token``, ready to wire into ``MymeClient``.
    /// - Throws: ``DeviceFlowError`` for terminal device-flow errors
    ///   (``DeviceFlowError/Code/accessDenied``,
    ///   ``DeviceFlowError/Code/expiredToken``); ``OAuthError`` for
    ///   protocol-level failures.
    public func awaitToken() async throws -> TokenProvider {
        while true {
            if Date() >= expiresAt {
                throw DeviceFlowError(rawCode: "expired_token", message: "device code expired")
            }
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)

            let result = try await poll()
            switch result {
            case .pending:
                continue
            case .slowDown:
                interval += 5
                continue
            case .granted(let token):
                let storageKey = "myme.auth.tokens:\(issuer.host ?? issuer.absoluteString):\(clientId)"
                let provider = StoredTokenProvider(
                    storage: storage,
                    storageKey: storageKey,
                    tokenEndpoint: issuer.appendingPathComponent("auth/token"),
                    clientId: clientId,
                    urlSession: urlSession
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
        var request = URLRequest(url: issuer.appendingPathComponent("auth/device/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": deviceCode,
            "client_id": clientId,
        ]
        request.httpBody = formURLEncode(body).data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
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
