import Foundation
import Marfa
import MarfaTypes

/// How the server answered a request to change the owner's password.
///
/// Only the refusals an app shows the owner in its own words are cases. Everything else, such as the server not
/// answering or the app's sign-in having ended, is thrown by ``Client/changePassword(from:to:)`` as a
/// ``MarfaError``.
public enum PasswordChangeOutcome: Sendable, Hashable {
    /// The new password is in force. Every browser sign-in of the owner has ended; keys and apps keep their access.
    case changed
    /// The current password sent is wrong, and nothing changed. It counts as a password attempt at the owner's
    /// sign-in, so it counts toward ``tooManyAttempts(retryAfterSeconds:)``.
    case currentPasswordWrong(message: String)
    /// The server holds the new password to its rules, such as a length of 8 to 128 characters, and refused it. Nothing
    /// changed.
    case newPasswordRefused(message: String)
    /// The credential lacks the permission that changes the password, `requiredScope` as the server names it, which is
    /// `sign_ins.manage`. Nothing changed.
    case notPermitted(requiredScope: String?, message: String)
    /// Too many passwords were tried for the owner, so the server judged none. Try again after `retryAfterSeconds`,
    /// where the server says.
    case tooManyAttempts(retryAfterSeconds: UInt64?)
}

extension Client {
    /// Replaces the owner's password with `new` once `current` proves right.
    ///
    /// Needs `sign_ins.manage`. The change ends every browser sign-in of the owner and keeps every key and every
    /// connected app. Neither password is kept, logged or sent anywhere but this call's request body.
    ///
    /// The server answers a wrong current password with the same `401` it gives a token it does not accept, and a
    /// request that is answered `401` is otherwise renewed and sent again, which would count the owner's wrong
    /// password twice. So this call first makes one cheap call under the same permission, which renews an expired
    /// token and refuses a credential without the permission before any password is sent, and then sends the
    /// password once. A `401` to that first call is thrown as ``MarfaError/unauthorized(code:message:server:)``, and
    /// a `401` to the change is ``PasswordChangeOutcome/currentPasswordWrong(message:)``. A token that ends between
    /// the two calls is answered the same `401`, so it reads as a wrong password too, and the server has not counted
    /// it as one.
    ///
    /// An answer this call cannot tell for certain, such as a connection lost after the request left, throws, and the
    /// password may or may not have changed: the owner's next sign-in with the new password shows which.
    public func changePassword(from current: String, to new: String) async throws(MarfaError)
        -> PasswordChangeOutcome
    {
        do {
            _ = try await answer("listSignIns") { try await listSignIns().ok }
        } catch {
            if case .forbidden = error, let outcome = Self.outcome(of: error) { return outcome }
            throw error
        }
        let body = Operations.ReplaceOwnerPassword.Input.Body.JsonPayload(currentPassword: current, newPassword: new)
        do {
            _ = try await answer("replaceOwnerPassword") { try await replaceOwnerPassword(body: .json(body)).ok }
            return .changed
        } catch {
            if let outcome = Self.outcome(of: error) { return outcome }
            throw error
        }
    }

    private static func outcome(of error: MarfaError) -> PasswordChangeOutcome? {
        switch error {
        case .unauthorized(_, let message, _): .currentPasswordWrong(message: message)
        case .validation(let code, let message, _, _) where code == "validation_error":
            .newPasswordRefused(message: message)
        case .forbidden(_, let message, let server):
            .notPermitted(requiredScope: server?.details?.object?["required_scope"]?.string, message: message)
        case .rateLimited(_, _, let retryAfter, _): .tooManyAttempts(retryAfterSeconds: retryAfter)
        default: nil
        }
    }
}
