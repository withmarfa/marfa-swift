#if canImport(AuthenticationServices)

import AuthenticationServices
import Foundation

/// Passkey enrolment for OAuth-bearer-driven Marfa apps.
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
/// shim to authenticate them with `marfa_at_*` access tokens, so the
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
/// - **Sign-in** — use ``MarfaAuth/signIn(presentationContextProvider:)``.
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
    ///   - issuer: Marfa instance base URL (e.g. `https://staging.marfa.so`).
    ///   - presentationContextProvider: SwiftUI/UIKit context provider for
    ///     the system browser window.
    ///   - callbackURLScheme: Custom scheme passed to the underlying
    ///     `ASWebAuthenticationSession`. The enrolment flow has no
    ///     server-side redirect to a custom scheme — the user dismissing
    ///     the window IS the completion signal — so the scheme just has
    ///     to be a valid identifier (default `marfa-auth-host`).
    ///
    /// Returns when the user dismisses the enrolment window. Whether
    /// enrolment actually succeeded is **not observable** from this side
    /// — `/auth/passkey/enroll` doesn't redirect to a custom scheme on
    /// completion or failure, so any dismissal looks identical to the
    /// SDK. Callers verify enrolment by attempting a passkey-backed
    /// sign-in: the OAuth sign-in page surfaces a "Use a passkey" button
    /// once a credential is stored against the account. Never throws on
    /// user dismissal — would be misleading given we can't tell success
    /// from cancellation.
    public static func enroll(
        issuer: URL,
        presentationContextProvider: ASWebAuthenticationPresentationContextProviding,
        callbackURLScheme: String = "marfa-auth-host"
    ) async {
        let url = issuer.appendingPathComponent("auth/passkey/enroll")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme
            ) { _, _ in
                // The completion handler fires either on a custom-scheme
                // callback URL (never happens for the enrol page) or on
                // the user closing the window (`canceledLogin`). Both
                // paths resume successfully — see method doc for why.
                continuation.resume()
            }
            session.presentationContextProvider = presentationContextProvider
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }
    }
}

#endif
