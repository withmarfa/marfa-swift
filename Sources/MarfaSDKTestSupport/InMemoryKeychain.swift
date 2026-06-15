import Foundation
import MarfaSDK

/// In-memory `SecureStorage` for unit tests. No Security framework calls;
/// no code-signing required. Actor-isolated so concurrent callers
/// serialize.
public actor InMemoryKeychain: SecureStorage {

    private var store: [String: String] = [:]

    public init() {}

    public func set(_ value: String, for account: String) async throws {
        store[account] = value
    }

    public func get(for account: String) async throws -> String? {
        store[account]
    }

    public func delete(for account: String) async throws {
        store.removeValue(forKey: account)
    }

    /// Test-only helper — direct read without going through the protocol.
    public func peek(account: String) -> String? {
        store[account]
    }

    /// Test-only helper — clear everything.
    public func reset() {
        store.removeAll()
    }
}
