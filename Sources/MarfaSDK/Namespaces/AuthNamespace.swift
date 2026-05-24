import Foundation

/// Account-management REST surface (T-116). Distinct from the OAuth /
/// Passkey / DeviceFlow ceremony exposed under ``MarfaAuth``, ``Passkey``,
/// and ``DeviceFlow`` — those run the sign-in dance and produce a
/// ``TokenProvider``. This namespace targets the post-sign-in
/// account-lifecycle endpoints (`/auth/account/...`).
///
/// **Authentication shape.** The server accepts EITHER a bearer
/// (tenant_admin / admin in the user's tenant) OR a better-auth session
/// cookie on these endpoints. The Swift SDK always sends the bearer; CLI
/// and SDK callers operating with an API key or an OAuth token just work.
/// Web flows that need the cookie path use the browser directly.
///
/// A client created via ``MarfaClient/local(path:)`` has no live server;
/// every method here throws ``LocalModeUnsupportedError``.
public struct AuthNamespace: Sendable {

    let transport: any Transport
    let isLocalMode: Bool

    /// Account-lifecycle endpoints — request a deletion, cancel an
    /// in-flight one, and the client-side surface for the
    /// email-confirmation link.
    public var account: AuthAccountNamespace {
        AuthAccountNamespace(transport: transport, isLocalMode: isLocalMode)
    }
}

/// Account-lifecycle endpoints (T-116). Deletion is two-phase: an
/// initial request mints a confirmation token and dispatches the
/// confirmation email; the user clicks the link (or the CLI calls
/// ``confirmDelete(token:)``) which arms the grace window; cancel
/// short-circuits before the purger sweeps.
public struct AuthAccountNamespace: Sendable {

    let transport: any Transport
    let isLocalMode: Bool

    private func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Initiate deletion. Mints a confirm token and dispatches the
    /// confirmation email. Returns when the request is accepted
    /// (HTTP 202). Idempotent within the token TTL — a second call inside
    /// the window re-uses the in-flight token rather than minting a new
    /// one, which keeps the per-account cancel-email throttle effective
    /// (see `MARFA_ACCOUNT_DELETE_CANCEL_COOLDOWN_MS`).
    public func requestDelete() async throws {
        try ensureRemote("auth.account.requestDelete")
        let _: EmptyResponse = try await transport.request(
            method: .post,
            path: "/auth/account/delete",
            body: nil,
            query: nil
        )
    }

    /// Consume a confirmation token. The server's GET response is an
    /// HTML page intended for the email recipient's browser; this helper
    /// exposes the same effect to programmatic callers (CLI, integration
    /// tests, headless workflows). Throws on bad / expired tokens.
    public func confirmDelete(token: String) async throws {
        try ensureRemote("auth.account.confirmDelete")
        let query: [(String, String)] = [("token", token)]
        let (responseData, response) = try await transport.rawRequest(
            method: .get,
            path: "/auth/account/delete/confirm",
            body: nil,
            contentType: nil,
            query: query
        )
        guard (200..<300).contains(response.statusCode) else {
            throw parseMarfaError(data: responseData, statusCode: response.statusCode)
        }
    }

    /// Cancel an in-flight deletion. Reverses the pending-delete state
    /// and clears the outstanding confirm token. Throws if the account
    /// is not in pending-deletion.
    public func cancel() async throws {
        try ensureRemote("auth.account.cancel")
        let _: EmptyResponse = try await transport.request(
            method: .post,
            path: "/auth/account/delete/cancel",
            body: nil,
            query: nil
        )
    }
}
