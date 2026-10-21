import Foundation

/// A working copy holds the key in memory and never writes it to its store.
public struct Server: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var url: URL
    /// An API key, or for a server made from a credential, the access token kept when it was made.
    public var key: String
    /// The sign-in the server was made from, which a copy or ``Folders`` renews when the server refuses its
    /// access token; `nil` for a server made from a key.
    public let credential: Credential?

    public init(url: URL, key: String) {
        self.url = url
        self.key = key
        credential = nil
    }

    /// The server at `url`, signed in to with `credential`.
    ///
    /// A ``WorkingCopy`` or ``Folders`` opened on it sends the access token kept at the time and renews it
    /// whenever the server refuses it. Once the server ends the sign-in, calls throw
    /// ``MarfaError/signedOut(origin:message:)`` until the app signs in again.
    ///
    /// Throws ``SignInError/notSignedIn`` when the keychain no longer holds the sign-in. `url` must be on
    /// the server the credential is for.
    public init(url: URL, credential: Credential) throws {
        precondition(
            origin(of: url) == credential.place.account, "a credential is used only on the server it is for")
        guard let token = try credential.accessToken() else { throw SignInError.notSignedIn }
        self.url = url
        key = token
        self.credential = credential
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
