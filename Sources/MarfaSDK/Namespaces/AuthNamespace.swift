import Foundation

/// Account-management REST surface. Distinct from the OAuth / Passkey /
/// DeviceFlow ceremony exposed under ``MarfaAuth``, ``Passkey``, and
/// ``DeviceFlow`` — those run the sign-in dance and produce a
/// ``TokenProvider``. This namespace targets the post-sign-in
/// account-lifecycle endpoints (`/auth/account/...`).
///
/// **Authentication shape.** The server accepts EITHER a bearer
/// (space_admin / admin in the user's space) OR a better-auth session
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

    /// Who this client's credential belongs to.
    ///
    /// `GET /auth/me`. The server resolves it from the credential, so nothing
    /// is passed on the wire and the answer is whoever is holding it.
    ///
    /// `space` is always present and `space.id` is the value worth having: it
    /// is per-account, assigned at provisioning, and identical for an API key
    /// and an OAuth token reaching the same account. `user` is `nil` for a
    /// credential with no person behind it, which is the ordinary case for an
    /// API key — so read identity from `space`, not from `user`.
    ///
    /// Use ``MarfaClient/accountIdentity()`` rather than this when the question
    /// is "whose store is this", since it pairs the space id with the server it
    /// came from; the same space id on two deployments is two different places.
    public func me() async throws -> AuthMe {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: "auth.me")
        }
        return try await transport.request(
            method: .get,
            path: "/auth/me",
            body: nil,
            query: nil
        )
    }
}

/// Account-lifecycle endpoints. Deletion is two-phase: an initial request
/// mints a confirmation token and dispatches the confirmation email; the
/// user clicks the link (or the CLI calls ``confirmDelete(token:)``) which
/// arms the grace window; cancel short-circuits before the purger sweeps.
public struct AuthAccountNamespace: Sendable {

    let transport: any Transport
    let isLocalMode: Bool

    private func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Initiate deletion. Mints a confirm token and dispatches the
    /// confirmation email. Returns when the request is accepted (HTTP 202).
    /// Idempotent within the token TTL — a second call inside the window
    /// re-uses the in-flight token rather than minting a new one.
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
