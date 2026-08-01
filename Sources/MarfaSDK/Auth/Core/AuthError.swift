import Foundation

/// OAuth 2.0 protocol error returned by the discovered token and
/// revocation endpoints, and the token-exchange leg of every auth flow.
///
/// Mapped from the wire's `{ "error": "...", "error_description": "..." }`
/// envelope per RFC 6749 §5.2. Pattern-match on ``code`` for branching:
///
///     do {
///         try await client.auth.signIn(...)
///     } catch let error as OAuthError where error.code == .invalidGrant {
///         // ask the user to sign in again
///     }
public final class OAuthError: MarfaError {
    /// RFC 6749 §5.2 error code, e.g. `invalid_grant`, `invalid_client`,
    /// `unauthorized_client`. Unknown values are preserved as
    /// ``Code/unknown`` and the raw string is available via
    /// ``MarfaError/code``.
    public enum Code: String, Sendable {
        case invalidRequest = "invalid_request"
        case invalidClient = "invalid_client"
        case invalidGrant = "invalid_grant"
        case unauthorizedClient = "unauthorized_client"
        case unsupportedGrantType = "unsupported_grant_type"
        case invalidScope = "invalid_scope"
        /// A refresh token was replayed after its successor had been issued.
        /// Refresh-token rotation invalidates both halves of the pair on
        /// reuse, so the grant is gone and the flow must start over.
        case tokenReuseDetected = "token_reuse_detected"
        case unknown
    }

    public let oauthCode: Code

    public init(rawCode: String, message: String, status: Int = 400, details: [String: JSONValue]? = nil) {
        self.oauthCode = Code(rawValue: rawCode) ?? .unknown
        super.init(code: rawCode, message: message, status: status, details: details)
    }
}

/// RFC 8628 Device Authorization Grant errors raised during the polling
/// loop on the device-flow polling endpoint.
public final class DeviceFlowError: MarfaError {
    public enum Code: String, Sendable {
        /// The user has not yet completed the verification step. The
        /// polling loop should keep going.
        case authorizationPending = "authorization_pending"
        /// The client is polling too quickly — increase the interval per
        /// the server's hint and try again.
        case slowDown = "slow_down"
        /// The user denied the authorization request. Terminal.
        case accessDenied = "access_denied"
        /// The device code expired before the user completed verification.
        /// Terminal — start a fresh flow.
        case expiredToken = "expired_token"
        case unknown
    }

    public let deviceCode: Code

    public init(rawCode: String, message: String, details: [String: JSONValue]? = nil) {
        self.deviceCode = Code(rawValue: rawCode) ?? .unknown
        super.init(code: rawCode, message: message, status: 400, details: details)
    }
}

/// Failures raised by the WebAuthn / passkey flow.
public final class PasskeyError: MarfaError {
    public enum Code: String, Sendable {
        /// The platform authenticator returned no credential — the user
        /// likely cancelled the system sheet.
        case userCancelled = "user_cancelled"
        /// The server rejected the attestation or assertion as invalid.
        case verificationFailed = "verification_failed"
        /// Passkey is unsupported on this platform / OS combination.
        case unsupported = "unsupported"
        case unknown
    }

    public let passkeyCode: Code

    public init(rawCode: String, message: String, details: [String: JSONValue]? = nil) {
        self.passkeyCode = Code(rawValue: rawCode) ?? .unknown
        super.init(code: rawCode, message: message, status: 400, details: details)
    }
}
