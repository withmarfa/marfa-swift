import Foundation

/// A working copy holds the key in memory and never writes it to its store.
public struct Server: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var url: URL
    public var key: String

    public init(url: URL, key: String) {
        self.url = url
        self.key = key
    }

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

    /// The server `MARFA_API_URL` and `MARFA_API_KEY` name, or `nil` when neither is set.
    ///
    /// One without the other, or an address that names no server, throws rather than answering `nil`, so an
    /// app that falls back to the keychain on `nil` never does so in a run meant to be unattended.
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

    /// Never shows the key.
    public var description: String { "Server(\(url.absoluteString))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["url": url]) }
}
