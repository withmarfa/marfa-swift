import Foundation

/// `LocalizedError` as well as `CustomStringConvertible`: this type is
/// internal, but `MarfaAuth.signIn`, `MarfaAuth.restore` and `DeviceFlow.start`
/// all throw it out through public API, so a consumer only ever sees it as
/// `localizedDescription`. Without the conformance that reads as a bare case
/// index rather than as the malformed issuer it is complaining about.
enum OAuthIssuerValidationError: Error, Sendable, CustomStringConvertible, LocalizedError {
    case notAbsolute(String)
    case userInfo(String)
    case query(String)
    case fragment(String)

    var description: String {
        switch self {
        case .notAbsolute(let issuer):
            return "OAuth issuer must be an absolute URL with a scheme and host: \(issuer)"
        case .userInfo(let issuer):
            return "OAuth issuer must not contain user information: \(issuer)"
        case .query(let issuer):
            return "OAuth issuer must not contain a query: \(issuer)"
        case .fragment(let issuer):
            return "OAuth issuer must not contain a fragment: \(issuer)"
        }
    }

    var errorDescription: String? { description }
}

/// Canonical OAuth issuer identity shared by discovery and credential storage.
///
/// Issuer paths and ports identify distinct authorization servers. Keeping the
/// full normalized URL in storage and cache keys prevents credentials from one
/// space or local development server being reused by another.
enum OAuthIssuer {

    static func normalize(_ url: URL) -> URL {
        (try? canonicalURL(url)) ?? url
    }

    static func canonicalURL(_ url: URL) throws -> URL {
        let raw = url.absoluteString
        guard url.baseURL == nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, !scheme.isEmpty,
              let host = components.host, !host.isEmpty
        else {
            throw OAuthIssuerValidationError.notAbsolute(raw)
        }
        guard components.user == nil, components.password == nil else {
            throw OAuthIssuerValidationError.userInfo(raw)
        }
        guard components.query == nil else {
            throw OAuthIssuerValidationError.query(raw)
        }
        guard components.fragment == nil else {
            throw OAuthIssuerValidationError.fragment(raw)
        }

        components.scheme = scheme.lowercased()
        components.host = host.lowercased()

        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" {
            path = ""
        }
        components.percentEncodedPath = path

        guard let canonical = components.url else {
            throw OAuthIssuerValidationError.notAbsolute(raw)
        }
        return canonical
    }

    static func identity(for issuer: URL) -> String {
        normalize(issuer).absoluteString
    }

    /// Account name for a versioned credential slot.
    ///
    /// The `.v2` separator is load-bearing. A legacy account is always
    /// `marfa.auth.tokens:<host>:<clientId>` — a colon directly after the
    /// kind — and both `host` and `clientId` are attacker-influenced. A `:v2:`
    /// prefix would therefore be reachable from a legacy account whose host is
    /// literally `v2`, letting one account's key address another account's
    /// slot. Separating the version with `.` instead of `:` makes the two
    /// namespaces disjoint by construction, because a legacy key can never
    /// carry a `.` in that position.
    static func storageKey(
        kind: String,
        issuer: URL,
        clientId: String
    ) -> String {
        let issuerField = lengthPrefixed(identity(for: issuer))
        let clientField = lengthPrefixed(clientId)
        return "marfa.auth.\(kind).v2:\(issuerField):\(clientField)"
    }

    static func legacyTokenStorageKey(
        issuer: URL,
        clientId: String
    ) -> String {
        legacyStorageKey(kind: "tokens", issuer: issuer, clientId: clientId)
    }

    /// The pre-11.4.0 spelling: host-only, no length prefix, no version.
    ///
    /// Only the token account is migrated on restore, because that is the one
    /// carrying a credential. Clearing a session has to reach the others too —
    /// a half-finished authorization left behind under the old spelling is
    /// state the user asked to be rid of.
    static func legacyStorageKey(
        kind: String,
        issuer: URL,
        clientId: String
    ) -> String {
        "marfa.auth.\(kind):\(issuer.host ?? issuer.absoluteString):\(clientId)"
    }

    /// Promotes the old host-only token account only for an unambiguous issuer.
    /// A path, explicit port, or non-HTTPS scheme could have shared that old
    /// account with a different authorization server, so those shapes never
    /// claim it automatically.
    static func migrateLegacyRootTokenIfNeeded(
        in storage: any SecureStorage,
        issuer: URL,
        clientId: String
    ) async throws -> Bool {
        let canonicalIssuer = try canonicalURL(issuer)
        guard let components = URLComponents(
            url: canonicalIssuer,
            resolvingAgainstBaseURL: false
        ), components.scheme == "https", components.port == nil,
              components.percentEncodedPath.isEmpty
        else {
            return false
        }

        let canonicalKey = storageKey(
            kind: "tokens",
            issuer: canonicalIssuer,
            clientId: clientId
        )
        let legacyKey = legacyTokenStorageKey(
            issuer: canonicalIssuer,
            clientId: clientId
        )

        return try await legacyTokenMigrationLock.withLock {
            guard try await storage.get(for: canonicalKey) == nil,
                  let legacyValue = try await storage.get(for: legacyKey),
                  try await storage.get(for: canonicalKey) == nil
            else {
                return false
            }

            // Write before deleting so a failed delete leaves two usable
            // copies rather than losing the only credential.
            try await storage.set(legacyValue, for: canonicalKey)
            try await storage.delete(for: legacyKey)
            return true
        }
    }

    private static func lengthPrefixed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}

private let legacyTokenMigrationLock = OAuthLegacyTokenMigrationLock()

/// Async mutex rather than a plain actor method: actor methods are reentrant
/// at storage awaits, which would let two restores both observe an empty
/// canonical account and promote the same legacy value.
private actor OAuthLegacyTokenMigrationLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        await acquire()
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        guard locked else {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            locked = false
            return
        }
        waiters.removeFirst().resume()
    }
}
