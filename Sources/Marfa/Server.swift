import Foundation

/// Where a working copy's slice comes from: a server, and the key that reaches it.
///
/// A working copy holds the key in memory and never writes it to its store;
/// `Keychain` keeps it between launches, where the caller chooses to.
public struct Server: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var url: URL
    public var key: String

    public init(url: URL, key: String) {
        self.url = url
        self.key = key
    }

    /// Why the environment's server could not be taken.
    public enum EnvironmentError: Error, Hashable, CustomStringConvertible {
        /// `MARFA_API_URL` is set, with a key beside it, and is not an http or https address with a host.
        case notAServer(String)

        public var description: String {
            switch self {
            case .notAServer(let url): "MARFA_API_URL is \(url), which is not an http or https address with a host"
            }
        }
    }

    /// The server `MARFA_API_URL` and `MARFA_API_KEY` name, where both are set, and nothing where either is
    /// missing or empty.
    ///
    /// A server named here takes the place of one kept in the Keychain, which a client then neither reads nor
    /// writes: this is how an agent or a test runs a client with nobody at the keyboard. An address that
    /// names no server is refused rather than passed over, so a mistyped one never falls back to a kept key.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(EnvironmentError) -> Server? {
        guard let text = environment["MARFA_API_URL"], !text.isEmpty,
            let key = environment["MARFA_API_KEY"], !key.isEmpty
        else { return nil }
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()),
            let host = url.host(), !host.isEmpty
        else { throw .notAServer(text) }
        return Server(url: url, key: key)
    }

    /// The server, never the key, so a log that prints one leaks nothing.
    public var description: String { "Server(\(url.absoluteString))" }
    public var debugDescription: String { description }
    /// The server alone, so `dump` and whatever else reflects on it leak
    /// nothing either.
    public var customMirror: Mirror { Mirror(self, children: ["url": url]) }
}
