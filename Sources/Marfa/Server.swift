import Foundation
internal import MarfaCore

/// A working copy holds the key in memory and never writes it to its store.
public struct Server: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Never holds a user or password: an address that names either is refused where a server is made.
    public private(set) var url: URL
    /// An API key, or for a server made from a credential, the access token kept when it was made.
    public var key: String
    /// The sign-in the server was made from, which a copy or ``Folders`` renews when the server refuses its
    /// access token; `nil` for a server made from a key.
    public let credential: Credential?
    /// How the owner is signed in again when the server asks, which ``confirming(from:prefersEphemeralWebBrowserSession:)``
    /// sets.
    var confirmation: Confirmation?

    /// Why an address cannot name a server.
    public enum AddressError: Error, Hashable, CustomStringConvertible {
        /// The address holds a user or a password, which a server address never carries: it would be kept
        /// and shown wherever the address is.
        case userInfo

        public var description: String {
            switch self {
            case .userInfo: "A server address holds no user or password."
            }
        }
    }

    /// The server at `url`, reached with the API key `key`.
    ///
    /// Throws ``AddressError/userInfo`` when `url` holds a user or a password.
    public init(url: URL, key: String) throws(AddressError) {
        try Self.refuseUserInfo(url)
        self.url = url
        self.key = key
        credential = nil
    }

    /// The server at `url`, signed in to with `credential`.
    ///
    /// A ``WorkingCopy`` or authenticated ``Folders`` call reads the current access token when it opens.
    /// The token can be renewed if the server refuses it.
    ///
    /// Throws ``SignInError/notAServer`` when `url` holds a user or a password, ``SignInError/otherServer`` when
    /// it is not on the server the credential is for, and ``SignInError/notSignedIn`` when the keychain no
    /// longer holds the sign-in.
    public init(url: URL, credential: Credential) throws {
        guard url.user() == nil, url.password() == nil else { throw SignInError.notAServer }
        guard Marfa.origin(of: url) == credential.place.account else { throw SignInError.otherServer }
        guard let token = try credential.accessToken() else { throw SignInError.notSignedIn }
        self.url = url
        key = token
        self.credential = credential
    }

    private static func refuseUserInfo(_ url: URL) throws(AddressError) {
        guard url.user() == nil, url.password() == nil else { throw .userInfo }
    }

    /// The token a copy or ``Folders`` opens with: the key, or the access token the keychain holds now.
    ///
    /// Throws ``SignInError/notSignedIn`` once the sign-in is gone, rather than sending the token ``key``
    /// held when the server was made.
    func openingToken() throws -> String {
        guard let credential else { return key }
        guard let token = try credential.accessToken() else { throw SignInError.notSignedIn }
        return token
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
                let host = url.host(), !host.isEmpty
            else { throw .notAServer }
            do {
                return try Server(url: url, key: key)
            } catch {
                throw .notAServer
            }
        }
    }

    public static func == (lhs: Server, rhs: Server) -> Bool {
        lhs.url == rhs.url && lhs.key == rhs.key && lhs.credential == rhs.credential
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(key)
        hasher.combine(credential)
    }

    /// Never shows the key.
    public var description: String { "Server(\(url.absoluteString))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["url": url]) }
}

extension Server {
    /// The origin a refusal or a redirect names: the server's scheme, host and port.
    package var origin: String { Marfa.origin(of: url) ?? url.absoluteString }

    /// The session a server made from a credential signs in through, which its requests share.
    package var signInSession: URLSession? { credential?.transport.session }

    /// The token a request sends now, as ``openingToken()`` reads it, refused as the working copy refuses it.
    package func currentToken() throws(MarfaError) -> String {
        do {
            return try openingToken()
        } catch SignInError.notSignedIn {
            throw .signedOut(origin: origin, message: "the app is not signed in to \(origin)")
        } catch {
            throw .noKeychain(message: "the keychain could not be read: \(error)")
        }
    }

    /// A token to send in place of `refused`, which the server refused, or `nil` for a server made from a key.
    package func renewedToken(refused: String) async throws(MarfaError) -> String? {
        guard let credential else { return nil }
        let renewer = TokenRenewer(credential)
        do {
            return try await background { try renewer.renew(refused: refused) }
        } catch RenewalError.Ended(let message) {
            throw .signedOut(origin: origin, message: message)
        } catch RenewalError.Unavailable(let message) {
            throw .network(message: message)
        } catch RenewalError.Refused(let reason, let message) {
            throw .renewalRefused(reason: RenewalRefusalReason(reason), message: message)
        } catch RenewalError.Failed(let message) {
            throw .invalid(message: message)
        } catch {
            throw .invalid(message: "the sign-in to \(origin) was not renewed: \(error)")
        }
    }
}
