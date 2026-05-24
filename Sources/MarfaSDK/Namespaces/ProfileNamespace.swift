import Foundation

/// Profile API namespace. Manages the calling user's `system.profile` —
/// a virtual type served from the `users`/`auth_user` join (not an
/// items-table row).
///
/// Apps that need a third-party-OAuth-style read should use the standard
/// OIDC `profile` / `email` scopes via `/auth/oauth2/userinfo` instead — this
/// surface is for first-party callers (CLI, MCP, the user themselves)
/// holding a tenant-scoped bearer.
///
/// In **pure-local mode** every method throws
/// ``LocalModeUnsupportedError`` — Profile lives on the server only.
public struct ProfileNamespace: Sendable {

    let transport: any Transport

    /// `true` when this namespace is attached to a pure-local client.
    let isLocalMode: Bool

    private func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Reads the calling user's profile from `GET /profile/me`.
    ///
    /// The server resolves "me" from the API key's tenant_id; no id is
    /// passed on the wire.
    public func get() async throws -> Profile {
        try ensureRemote("profile.get")
        return try await transport.request(
            method: .get, path: "/profile/me", body: nil, query: nil
        )
    }

    /// Updates the calling user's profile via `PATCH /profile/me`.
    ///
    /// Every field on ``UpdateProfileInput`` is optional. The `username`
    /// field runs through the reserved-handle / collision validators on
    /// the server; pass `nil` (omit) to leave it unchanged.
    public func update(_ input: UpdateProfileInput) async throws -> Profile {
        try ensureRemote("profile.update")
        return try await transport.request(
            method: .patch, path: "/profile/me", body: input, query: nil
        )
    }

    /// Uploads an avatar image via `POST /profile/me/avatar`.
    ///
    /// The server stores the bytes in the existing R2-backed blob layer
    /// and stamps the content-addressed hash onto the user row, returning
    /// the updated profile.
    ///
    /// `mimeType` should match the actual image format
    /// (e.g. `"image/png"`, `"image/jpeg"`); the server validates and
    /// rejects mismatches with `400 ValidationError`.
    public func uploadAvatar(_ data: Data, mimeType: String) async throws -> Profile {
        try ensureRemote("profile.uploadAvatar")
        let filename = filenameForMimeType(mimeType)
        let (responseData, response) = try await transport.uploadMultipart(
            method: .post,
            path: "/profile/me/avatar",
            fieldName: "file",
            filename: filename,
            data: data,
            mimeType: mimeType,
            query: nil
        )
        guard (200..<300).contains(response.statusCode) else {
            throw parseMarfaError(data: responseData, statusCode: response.statusCode)
        }
        let decoder = JSONDecoder()
        return try decoder.decode(Profile.self, from: responseData)
    }

    /// Deletes the avatar via `DELETE /profile/me/avatar`. Reverts to a
    /// deterministic placeholder URL.
    public func deleteAvatar() async throws -> Profile {
        try ensureRemote("profile.deleteAvatar")
        return try await transport.request(
            method: .delete, path: "/profile/me/avatar", body: nil, query: nil
        )
    }

    private func filenameForMimeType(_ mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": return "avatar.png"
        case "image/jpeg", "image/jpg": return "avatar.jpg"
        case "image/gif": return "avatar.gif"
        case "image/webp": return "avatar.webp"
        case "image/heic": return "avatar.heic"
        default: return "avatar"
        }
    }
}
