import AuthenticationServices
import Foundation
import SwiftUI

/// How a ``Server`` shows the owner the sign-in page when the server asks them to confirm it is them.
struct Confirmation: Sendable {
    let browser: @MainActor @Sendable (_ authorize: URL, _ scheme: String) async throws -> URL
}

extension Server {
    /// This server, set to sign the owner in again when the server asks, and to send the call once more.
    ///
    /// Restoring a backup, moving the sign-in address and turning on `allow_private_addresses` need the owner to have
    /// signed in within the last few minutes. When the server answers such a call with
    /// `401 insufficient_user_authentication` (RFC 9470), a server set up here shows the system's web authentication
    /// session over `anchor` with the `max_age` the server names, keeps the new sign-in, and sends the call once more
    /// with it. The app shows nothing itself.
    ///
    /// Only one sheet shows at a time, however many calls are waiting, and a call that waited sends again with the
    /// sign-in the first one made. A second challenge for the same call throws
    /// ``MarfaError/confirmationRequired(maxAgeSeconds:message:server:)`` and starts no more sheets, and a sheet the
    /// person closes throws ``MarfaError/canceled(message:)``. A person who declines throws
    /// ``MarfaError/forbidden(code:message:server:)`` with the code `access_denied`.
    ///
    /// Has no effect on a server made from a key, which has no sign-in to renew: the server refuses it these calls
    /// with ``MarfaError/appSignInRequired(message:server:)``. Nor does it help a sign-in made with the device grant,
    /// which has no browser to return to.
    public func confirming(
        from anchor: @escaping @MainActor @Sendable () -> ASPresentationAnchor,
        prefersEphemeralWebBrowserSession: Bool = false
    ) -> Server {
        confirming { url, scheme in
            try await WebSession.present(
                url, scheme: scheme, anchor: anchor(), ephemeral: prefersEphemeralWebBrowserSession)
        }
    }

    /// As ``confirming(from:prefersEphemeralWebBrowserSession:)``, through SwiftUI's `webAuthenticationSession`
    /// environment value.
    public func confirming(using session: WebAuthenticationSession) -> Server {
        confirming { url, scheme in
            do {
                return try await session.authenticate(
                    using: url, callback: .customScheme(scheme), additionalHeaderFields: [:])
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                throw SignInError.canceled
            }
        }
    }

    func confirming(_ browser: @escaping @MainActor @Sendable (URL, String) async throws -> URL) -> Server {
        var server = self
        server.confirmation = Confirmation(browser: browser)
        return server
    }

    /// The token to send again after `challenge`, which the server made of `refused`.
    ///
    /// Throws `challenge` where nothing can answer it.
    package func confirmedToken(refused: String, challenge: MarfaError) async throws(MarfaError) -> String {
        guard case .confirmationRequired(let maxAge, _, _) = challenge, let credential, let confirmation else {
            throw challenge
        }
        let gate = ConfirmationGate.shared
        await gate.enter()
        do {
            let token = try await Self.confirmed(
                refused: refused, maxAge: maxAge, credential: credential, confirmation: confirmation,
                challenge: challenge)
            await gate.leave()
            return token
        } catch {
            await gate.leave()
            throw error
        }
    }

    private static func confirmed(
        refused: String, maxAge: UInt64?, credential: Credential, confirmation: Confirmation,
        challenge: MarfaError
    ) async throws(MarfaError) -> String {
        do {
            // A call that waited for the sheet sends again with what the first call's sign-in kept.
            if let kept = try await background({ try credential.accessToken() }), kept != refused { return kept }
            let signedIn = try await credential.reauthorization().signIn(
                maxAge: maxAge, browser: confirmation.browser)
            guard let token = try await background({ try signedIn.accessToken() }) else {
                throw SignInError.notSignedIn
            }
            return token
        } catch let error as MarfaError {
            throw error
        } catch SignInError.noRedirect {
            throw challenge
        } catch SignInError.canceled, is CancellationError {
            throw .canceled(message: "the owner closed the sign-in before confirming")
        } catch SignInError.denied {
            throw .forbidden(
                code: "access_denied", message: "the owner did not approve the sign-in", server: nil)
        } catch SignInError.notSignedIn {
            throw .signedOut(origin: credential.server.absoluteString, message: "the app is no longer signed in")
        } catch SignInError.unavailable(let message) {
            throw .network(message: message)
        } catch {
            throw .invalid(message: "the owner's sign-in was not confirmed: \(error)")
        }
    }
}

/// Lets one confirmation run at a time, whichever server asks.
private actor ConfirmationGate {
    static let shared = ConfirmationGate()
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty {
            held = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
