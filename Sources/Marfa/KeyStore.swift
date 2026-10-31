import Foundation

/// Where an app keeps the key for each Marfa server between launches.
///
/// A store answers two different things that an app must not confuse. ``key(for:)`` returns `nil` when it holds no
/// key for the address, which asks the person to connect, and throws when it holds one it cannot read, which
/// asks nothing of them: a locked keychain or a refused prompt is not a lost key, and an app that treated it as one
/// would ask for a key the person still has.
public protocol KeyStore: Sendable {
    /// Keeps `key` for the server at `address`, replacing the one kept.
    func save(_ key: String, for address: URL) throws

    /// The key kept for `address`; `nil` where none is kept, and a throw where one is kept and cannot be read.
    func key(for address: URL) throws -> String?

    /// Forgets the key kept for `address`. Where none is kept, nothing happens.
    func delete(for address: URL) throws
}

/// The keys of an app, as generic passwords in a ``Keychain``, one account for each server address.
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

    /// One server is one account, so a key saved for one address is never read for another.
    static func account(for address: URL) -> String {
        address.absoluteString
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
