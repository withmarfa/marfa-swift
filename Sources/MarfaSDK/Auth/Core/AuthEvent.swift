import Foundation

/// Why a session ended, carried on ``AuthEvent/signedOut(reason:)``.
///
/// Every case is terminal: the stored tokens are gone and no amount of
/// retrying will bring them back. Only a fresh sign-in restores access.
public enum SignOutReason: String, Sendable, Hashable {
    /// The server rejected the refresh token (`invalid_grant`) — it expired,
    /// was revoked, or the grant was deleted.
    case refreshTokenRejected

    /// The server saw the refresh token used after its successor had already
    /// been issued (`token_reuse_detected`). Refresh-token rotation treats a
    /// replayed token as a possible theft and invalidates the whole pair, so
    /// this is terminal even though the credential worked moments earlier.
    case reuseDetected

    /// No refresh token is held, so there is nothing to exchange.
    case noRefreshToken
}

/// Authentication lifecycle events emitted by ``StoredTokenProvider``.
///
/// Subscribe through ``StoredTokenProvider/authEvents`` and treat a
/// ``signedOut(reason:)`` as "show the sign-in screen". This exists because a
/// dead session is invisible otherwise: calls simply keep failing, and an app
/// that responds by retrying will hammer the token endpoint instead of asking
/// the user to sign in.
public enum AuthEvent: Sendable, Hashable {
    /// The session ended and the persisted tokens were discarded. Prompt for
    /// sign-in; do not retry the call that failed.
    case signedOut(reason: SignOutReason)
}
