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
    ///
    /// Neither case repeats a value, which could be a key.
    public enum EnvironmentError: Error, Hashable, CustomStringConvertible {
        /// One of `MARFA_API_URL` and `MARFA_API_KEY` is set and the other is missing or empty.
        case incomplete(missing: String)
        /// `MARFA_API_URL` is not an http or https address with a host and no user or password in it.
        case notAServer

        public var description: String {
            switch self {
            case .incomplete(let missing):
                "\(missing) is not set, and the server needs both MARFA_API_URL and MARFA_API_KEY"
            case .notAServer: "MARFA_API_URL is not an http or https address with a host and no user or password"
            }
        }
    }

    /// The server `MARFA_API_URL` and `MARFA_API_KEY` name, where both are set, and nothing where neither is.
    ///
    /// A server named here takes the place of one kept in the Keychain, which a client then neither reads nor
    /// writes: this is how an agent or a test runs a client with nobody at the keyboard. One name without the
    /// other, or an address that names no server, is refused rather than passed over, so a run meant to be
    /// unattended never falls back to the Keychain and waits on a person there.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(EnvironmentError) -> Server? {
        let text = environment["MARFA_API_URL"].flatMap { $0.isEmpty ? nil : $0 }
        let key = environment["MARFA_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        switch (text, key) {
        case (nil, nil): return nil
        case (nil, _): throw .incomplete(missing: "MARFA_API_URL")
        case (_, nil): throw .incomplete(missing: "MARFA_API_KEY")
        case (let text?, let key?):
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()),
                let host = url.host(), !host.isEmpty, url.user() == nil, url.password() == nil
            else { throw .notAServer }
            return Server(url: url, key: key)
        }
    }

    /// The server, never the key, so a log that prints one leaks nothing.
    public var description: String { "Server(\(url.absoluteString))" }
    public var debugDescription: String { description }
    /// The server alone, so `dump` and whatever else reflects on it leak
    /// nothing either.
    public var customMirror: Mirror { Mirror(self, children: ["url": url]) }
}
