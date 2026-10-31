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

    private struct State {
        var keys: [URL: String]
        var unreadable: Set<URL> = []
    }

    private let state: Mutex<State>

    public init(_ keys: [URL: String] = [:]) {
        state = Mutex(State(keys: keys))
    }

    /// Makes reading the key for `address` throw ``Unreadable`` until the key is saved again or deleted.
    public func makeUnreadable(_ address: URL) {
        state.withLock { _ = $0.unreadable.insert(address) }
    }

    public func save(_ key: String, for address: URL) {
        state.withLock {
            $0.keys[address] = key
            $0.unreadable.remove(address)
        }
    }

    public func key(for address: URL) throws -> String? {
        try state.withLock {
            guard !$0.unreadable.contains(address) else { throw Unreadable() }
            return $0.keys[address]
        }
    }

    public func delete(for address: URL) {
        state.withLock {
            $0.keys.removeValue(forKey: address)
            $0.unreadable.remove(address)
        }
    }
}
#endif
