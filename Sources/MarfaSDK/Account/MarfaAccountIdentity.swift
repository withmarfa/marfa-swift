import Foundation
import CryptoKit

/// Which account a local store belongs to.
///
/// A local store is a file, and a credential is a thing that rotates. Neither
/// can answer "whose data is this", which is why every consumer holding both
/// has had to invent an answer:
///
/// - **An access token cannot serve.** It rotates on every silent refresh, so
///   comparing tokens reports a new account several times an hour.
/// - **An API key cannot serve either.** One account can hold several keys and
///   can be reached by more than one auth method, so a key comparison reports a
///   change where there is none — and, worse, reports *no* change when there is
///   no key recorded at all, which is the state an install is in after reaching
///   an account by OAuth. That gap is how one account's library came to be
///   uploaded into another's.
///
/// The space id is the value that survives both: it is per-account, assigned at
/// provisioning, and returned for an API key and an OAuth token alike. Paired
/// with the server it was read from, because the same space id on two
/// deployments is two different places.
public struct MarfaAccountIdentity: Sendable, Equatable, Hashable, Codable {

    /// The server this identity was read from, canonicalized.
    public let serverOrigin: String

    /// The space id behind the credential that read it.
    public let spaceId: String

    /// A stable, opaque handle for this identity.
    ///
    /// Safe to put in a file name or a defaults key: it is hex, fixed length,
    /// and carries neither the host nor the space id in readable form. Derived
    /// rather than random so the same account always produces the same handle,
    /// on this device and on any other.
    public var storageKey: String {
        let digest = SHA256.hash(data: Data("\(serverOrigin)\n\(spaceId)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// - Parameters:
    ///   - serverURL: The Marfa server. Canonicalized on the way in, so
    ///     `HTTPS://API.MARFA.SO:443/` and `https://api.marfa.so` are one
    ///     identity rather than two.
    ///   - spaceId: The space id, as returned by ``AuthNamespace/me()``.
    public init(serverURL: URL, spaceId: String) {
        self.serverOrigin = Self.canonicalOrigin(serverURL)
        self.spaceId = spaceId
    }

    /// Scheme and host lowercased, a default port dropped, and any trailing
    /// slash removed.
    ///
    /// Canonicalized here rather than through `OAuthIssuer`, which does most of
    /// this already: that type's exact output is a *credential storage key*,
    /// pinned by tests that exist because two spellings addressing one slot was
    /// a security bug. Widening it to also strip default ports would change
    /// where existing credentials live. This is a separate question that
    /// happens to look similar.
    private static func canonicalOrigin(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        if let port = components.port,
           (components.scheme == "https" && port == 443)
            || (components.scheme == "http" && port == 80) {
            components.port = nil
        }

        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path == "/" ? "" : path

        return components.url?.absoluteString ?? url.absoluteString
    }
}
