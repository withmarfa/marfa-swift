import Foundation

/// Canonical OAuth issuer identity shared by discovery and credential storage.
///
/// Issuer paths and ports identify distinct authorization servers. Keeping the
/// full normalized URL in storage and cache keys prevents credentials from one
/// tenant or local development server being reused by another.
enum OAuthIssuer {

    static func normalize(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" {
            path = ""
        }
        components.percentEncodedPath = path

        return components.url ?? url
    }

    static func identity(for issuer: URL) -> String {
        normalize(issuer).absoluteString
    }

    static func storageKey(
        kind: String,
        issuer: URL,
        clientId: String
    ) -> String {
        "marfa.auth.\(kind):\(identity(for: issuer)):\(clientId)"
    }

    static func legacyStorageKey(
        kind: String,
        issuer: URL,
        clientId: String
    ) -> String {
        "marfa.auth.\(kind):\(issuer.host ?? issuer.absoluteString):\(clientId)"
    }

    /// Promotes the pre-issuer-identity storage key only when the canonical
    /// key is absent. Writing before deleting makes the migration recoverable
    /// if storage fails part-way through the operation.
    static func migrateLegacyValueIfNeeded(
        in storage: any SecureStorage,
        canonicalKey: String,
        legacyKey: String
    ) async throws -> Bool {
        guard legacyKey != canonicalKey, try await storage.get(for: canonicalKey) == nil,
              let legacyValue = try await storage.get(for: legacyKey)
        else {
            return false
        }

        try await storage.set(legacyValue, for: canonicalKey)
        try await storage.delete(for: legacyKey)
        return true
    }
}
