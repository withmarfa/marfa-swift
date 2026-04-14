import Foundation

/// Asynchronous key-value secure storage contract.
///
/// Concrete implementations: ``KeychainStorage`` (production, backed by
/// Security.framework) and `InMemoryKeychain` in `MymeSDKTestSupport`
/// (tests, no code-signing required).
///
/// Protocol methods are `async` because the backing store may perform
/// serialized work on an actor; callers should always `await`.
public protocol SecureStorage: Sendable {
    /// Stores `value` at `account`, replacing any existing value.
    func set(_ value: String, for account: String) async throws

    /// Retrieves the value at `account`, or `nil` if not set.
    func get(for account: String) async throws -> String?

    /// Removes the value at `account`. No-op if not set.
    func delete(for account: String) async throws
}
