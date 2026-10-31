import Foundation

/// Where an app keeps the key for each Marfa server between launches.
///
/// A store answers two different things that an app must not confuse. ``key(for:)`` returns `nil` when it holds no
/// key for the address, which asks the person to connect, and throws when it holds one it cannot read, which
/// asks nothing of them: a locked keychain or a refused prompt is not a lost key, and an app that treated it as one
/// would ask for a key the person still has.
///
/// A store keeps one key for each server, and one server can be written several ways: addresses that differ only
/// in the case of the scheme or host, in naming the scheme's default port, or in a trailing `/`, are one server,
/// as ``account(for:)`` writes it.
public protocol KeyStore: Sendable {
    /// Keeps `key` for the server at `address`, replacing the one kept.
    func save(_ key: String, for address: URL) throws

    /// The key kept for `address`; `nil` where none is kept, and a throw where one is kept and cannot be read.
    func key(for address: URL) throws -> String?

    /// Forgets the key kept for `address`. Where none is kept, nothing happens.
    func delete(for address: URL) throws
}

extension KeyStore {
    /// The address of a server written one way, which a store keeps its key under: the scheme and host in lowercase,
    /// no port where it is the scheme's default, and no trailing `/`.
    public static func account(for address: URL) -> String {
        guard var parts = URLComponents(url: address, resolvingAgainstBaseURL: true) else {
            return address.absoluteString
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.percentEncodedHost = parts.percentEncodedHost?.lowercased()
        switch (parts.scheme, parts.port) {
        case ("http", 80), ("https", 443): parts.port = nil
        default: break
        }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        parts.percentEncodedPath = path
        return parts.string ?? address.absoluteString
    }
}

/// The keys of an app, as generic passwords in a ``Keychain``, one account for each server, named by
/// ``KeyStore/account(for:)``.
public struct KeychainKeyStore: KeyStore {
    /// The service the keys are kept under: the app's bundle identifier followed by `.marfa-key`.
    ///
    /// Naming it for the bundle identifier means a build with its own, such as a Debug build, never reads or
    /// replaces the keys of the installed app. A process with no bundle identifier uses `com.withmarfa.marfa`.
    public static var defaultService: String { "\(Bundle.main.bundleIdentifier ?? "com.withmarfa.marfa").marfa-key" }

    public let service: String
    private let keychain: Keychain

    /// A store in `keychain`, under `service`.
    public init(keychain: Keychain = .system, service: String = KeychainKeyStore.defaultService) {
        self.keychain = keychain
        self.service = service
    }

    public func save(_ key: String, for address: URL) throws {
        try keychain.save(key: key, service: service, account: Self.account(for: address))
    }

    public func key(for address: URL) throws -> String? {
        try keychain.key(service: service, account: Self.account(for: address))
    }

    public func delete(for address: URL) throws {
        try keychain.delete(service: service, account: Self.account(for: address))
    }
}
