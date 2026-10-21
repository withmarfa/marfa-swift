import AuthenticationServices
import SwiftUI

extension Authorization {
    /// Signs in through SwiftUI's `webAuthenticationSession` environment value.
    ///
    /// Throws as ``signIn(presentingFrom:prefersEphemeralWebBrowserSession:)`` does.
    @MainActor
    public func signIn(using session: WebAuthenticationSession) async throws -> Credential {
        try await signIn { url, scheme in
            do {
                return try await session.authenticate(
                    using: url, callback: .customScheme(scheme), additionalHeaderFields: [:])
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                throw SignInError.canceled
            }
        }
    }
}
