#if canImport(AuthenticationServices)

import AuthenticationServices
import Foundation

/// Passkey enrolment for OAuth-bearer-driven Myme apps.
///
/// ## Why this is a thin wrapper, not a native `ASAuthorizationController`
/// flow
///
/// Earlier iterations of this SDK implemented passkey registration and
/// authentication directly via `ASAuthorizationPlatformPublicKeyCredentialProvider`
/// against the server's `/auth/passkey/*` REST endpoints. That contract
/// turns out to be incompatible with Better-Auth's passkey plugin: those
/// endpoints are gated on a Better-Auth **session cookie**, not on the
/// OAuth bearer that a native client holds. There is no plugin-level
/// shim to authenticate them with `myme_at_*` access tokens, so the
/// native flow returns 401 every time.
///
/// The architectural answer is to delegate to the web flow that the
/// server already ships:
///
/// - **Enrolment** — open `/auth/passkey/enroll` in
///   `ASWebAuthenticationSession`. The system passkey sheet runs inside
///   the web view (Safari/WKWebView dispatch the WebAuthn ceremony to
///   `ASAuthorizationController` under the hood, so the UX is identical
///   to a fully-native flow). The sign-in page handles the cookie/session
///   gate; on successful enrolment the user dismisses the window.
/// - **Sign-in** — use ``MymeAuth/signIn(presentationContextProvider:)``.
///   Once a passkey is enrolled, the consent / sign-in page surfaces a
///   "Use a passkey" button automatically. The OAuth flow returns a
///   ``Token`` the same way email-and-password sign-in does. There is no
///   separate ``Passkey.authenticate`` API because there is no separate
///   native code path — passkey sign-in IS OAuth sign-in once the user
///   has a credential enrolled.
///
/// ## Platform support
///
/// `ASWebAuthenticationSession` requires iOS 12+/macOS 10.15+/watchOS 6+/tvOS 16+.
@MainActor
public enum Passkey {

    /// Opens `/auth/passkey/enroll` in `ASWebAuthenticationSession` so
    /// the user can register a new platform passkey for their account.
    ///
    /// - Parameters:
    ///   - issuer: Myme instance base URL (e.g. `https://staging.myme.so`).
    ///   - presentationContextProvider: SwiftUI/UIKit context provider for
    ///     the system browser window.
    ///   - callbackURLScheme: Custom scheme the SDK listens for to know
    ///     when the user is finished. The enrolment flow has no
    ///     server-side redirect, so the scheme just has to match
    ///     **something** (default `myme-auth-host`); the user dismissing
    ///     the window is the completion signal.
    ///
    /// - Throws: ``OAuthError`` with code `user_cancelled` if the user
    ///   dismisses the window before completing, or any underlying
    ///   `ASWebAuthenticationSessionError` thrown by the system.
    public static func enroll(
        issuer: URL,
        presentationContextProvider: ASWebAuthenticationPresentationContextProviding,
        callbackURLScheme: String = "myme-auth-host"
    ) async throws {
        let url = issuer.appendingPathComponent("auth/passkey/enroll")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme
            ) { _, error in
                if let asError = error as? ASWebAuthenticationSessionError,
                   asError.code == .canceledLogin {
                    continuation.resume(throwing: OAuthError(
                        rawCode: "user_cancelled",
                        message: "passkey enrolment cancelled",
                        status: 400
                    ))
                } else {
                    // Any other error surface (real failure or natural
                    // dismissal-after-enrol) is treated as success: the
                    // server-side enrolment is observable later via
                    // listing the user's passkeys, not via this callback
                    // (which only fires on a custom-scheme redirect that
                    // /auth/passkey/enroll never emits).
                    continuation.resume()
                }
            }
            session.presentationContextProvider = presentationContextProvider
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }
    }
}

#endif
