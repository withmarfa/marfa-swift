#if DEBUG
import Foundation
import Marfa
import Synchronization

/// A ``KeyStore`` that keeps its keys in memory for the life of the object, so a test never reaches a keychain.
///
/// ``makeUnreadable(_:)`` turns a key into one the store holds but cannot read, which is how a test drives an
/// app's difference between no key and an unreadable one.
public final class MemoryKeyStore: KeyStore {
    /// What ``makeUnreadable(_:)`` makes a read throw.
    public struct Unreadable: Error, Hashable {
        public init() {}
    }

    /// Keyed by ``KeyStore/account(for:)``, as a ``KeychainKeyStore`` is.
    private struct State {
        var keys: [String: String]
        var unreadable: Set<String> = []
    }

    private let state: Mutex<State>

    public init(_ keys: [URL: String] = [:]) {
        state = Mutex(State(keys: Dictionary(keys.map { (Self.account(for: $0), $1) }) { $1 }))
    }

    /// Makes reading the key for `address` throw ``Unreadable`` until the key is saved again or deleted.
    public func makeUnreadable(_ address: URL) {
        state.withLock { _ = $0.unreadable.insert(Self.account(for: address)) }
    }

    public func save(_ key: String, for address: URL) {
        let account = Self.account(for: address)
        state.withLock {
            $0.keys[account] = key
            $0.unreadable.remove(account)
        }
    }

    public func key(for address: URL) throws -> String? {
        let account = Self.account(for: address)
        return try state.withLock {
            guard !$0.unreadable.contains(account) else { throw Unreadable() }
            return $0.keys[account]
        }
    }

    public func delete(for address: URL) {
        let account = Self.account(for: address)
        state.withLock {
            $0.keys.removeValue(forKey: account)
            $0.unreadable.remove(account)
        }
    }
}
#endif
