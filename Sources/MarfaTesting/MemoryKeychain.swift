#if DEBUG
import Foundation
import Marfa
import Security
import Synchronization

/// A ``Keychain`` that keeps its items in memory for the life of the object, so a test never reads or writes a
/// system keychain and never raises a dialog.
///
/// ``keychain`` runs ``KeychainKeyStore``, ``Authorization`` and ``Credential`` through the same code a real
/// keychain does. ``failReads(with:)`` and ``failWrites(with:)`` make it refuse, which is how a test drives an app's
/// handling of a locked keychain or one that refuses a write.
///
/// Each one is a place of its own, as ``Keychain`` treats a test's keychain.
public final class MemoryKeychain: Sendable {
    private let items: Items

    /// The keychain to give ``KeychainKeyStore``, ``Authorization`` and the rest of the package.
    public let keychain: Keychain

    public init() {
        let items = Items()
        self.items = items
        keychain = Keychain(backend: items)
    }

    /// Makes every read throw ``Keychain/Failure`` with `status`, until ``succeed()``.
    ///
    /// A read is a key read, a check for a held item, or a check of a label.
    public func failReads(with status: OSStatus) {
        items.state.withLock { $0.readFailure = status }
    }

    /// Makes every write throw ``Keychain/Failure`` with `status`, until ``succeed()``.
    ///
    /// A write is a save, an add, a delete or a change of a label.
    public func failWrites(with status: OSStatus) {
        items.state.withLock { $0.writeFailure = status }
    }

    /// Stops failing reads and writes.
    ///
    /// What was kept is as it was.
    public func succeed() {
        items.state.withLock {
            $0.readFailure = nil
            $0.writeFailure = nil
        }
    }

    /// The credential of a sign-in kept in this keychain under `service`, as an approval would have kept it,
    /// with no browser and no server.
    ///
    /// It is the sign-in ``Authorization/credential()`` reads, so ``Server/init(url:credential:)`` opens on it and
    /// ``Credential/grants(_:)`` reads `scopes`. A credential has no expiry of its own: the server refuses an access
    /// token, and the credential renews it with its refresh token. These are the two ends a test can drive:
    ///
    /// - With no `refreshToken`, a refused access token ends the sign-in as it does for a real one that holds none:
    ///   the renewal drops it and calls throw ``MarfaError/signedOut(origin:message:)``.
    /// - With a `refreshToken`, a renewal reaches no server, which a stand-in has none of, so it fails as one that
    ///   cannot be reached does: ``MarfaError/network(message:)``, with the sign-in kept.
    ///
    /// Throws ``SignInError/notAServer`` for an address that is not an `http` or `https` address with a host and no
    /// user or password, and a ``Keychain/Failure`` when the keychain refuses a read or write.
    public func signIn(
        to server: URL, service: String = "com.withmarfa.marfa-testing", accessToken: String = "memory-access-token",
        refreshToken: String? = nil, scopes: [String] = []
    ) throws -> Credential {
        try Credential.keeping(
            accessToken: accessToken, refreshToken: refreshToken, scopes: scopes, server: server, keychain: keychain,
            service: service, session: Self.unreachable)
    }

    private static let unreachable: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Unreachable.self]
        return URLSession(configuration: configuration)
    }()

    private struct Item {
        var data: Data
        var label: String?
    }

    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private struct State {
        var items: [Key: Item] = [:]
        var readFailure: OSStatus?
        var writeFailure: OSStatus?
    }

    private final class Items: KeychainBackend {
        let state = Mutex(State())

        private func read<T>(_ work: (State) -> T) throws -> T {
            try state.withLock {
                if let status = $0.readFailure { throw Keychain.Failure(status: status) }
                return work($0)
            }
        }

        private func write<T>(_ work: (inout State) -> T) throws -> T {
            try state.withLock {
                if let status = $0.writeFailure { throw Keychain.Failure(status: status) }
                return work(&$0)
            }
        }

        func data(service: String, account: String) throws -> Data? {
            try read { $0.items[Key(service: service, account: account)]?.data }
        }

        func put(_ data: Data, service: String, account: String) throws {
            try write {
                let key = Key(service: service, account: account)
                $0.items[key, default: Item(data: data, label: nil)].data = data
            }
        }

        func delete(service: String, account: String) throws {
            try write { _ = $0.items.removeValue(forKey: Key(service: service, account: account)) }
        }

        func holds(service: String, account: String?) throws -> Bool {
            try read { state in
                state.items.keys.contains { $0.service == service && (account == nil || $0.account == account) }
            }
        }

        func add(label: String, service: String, account: String) throws -> Bool {
            try write {
                let key = Key(service: service, account: account)
                guard $0.items[key] == nil else { return false }
                $0.items[key] = Item(data: Data(), label: label)
                return true
            }
        }

        func label(service: String, account: String) throws -> String? {
            try read { state in state.items[Key(service: service, account: account)].map { $0.label ?? "" } }
        }

        func delete(label: String, service: String, account: String) throws {
            try write {
                let key = Key(service: service, account: account)
                if $0.items[key]?.label == label { $0.items.removeValue(forKey: key) }
            }
        }

        func relabel(from: String, to: String, service: String, account: String) throws -> Bool {
            try write {
                let key = Key(service: service, account: account)
                guard $0.items[key]?.label == from else { return false }
                $0.items[key]?.label = to
                return true
            }
        }
    }

    /// Answers every request with a refusal to connect, so a renewal in a test reaches no network.
    private final class Unreachable: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        override func stopLoading() {}
    }
}
#endif
