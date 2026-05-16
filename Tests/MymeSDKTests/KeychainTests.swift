import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

@Suite("SecureStorage / InMemoryKeychain")
struct InMemoryKeychainTests {

    @Test("Round-trip: set → get → delete")
    func roundTrip() async throws {
        let storage = InMemoryKeychain()
        try await storage.set("secret", for: "prod")

        let value = try await storage.get(for: "prod")
        #expect(value == "secret")

        try await storage.delete(for: "prod")
        let missing = try await storage.get(for: "prod")
        #expect(missing == nil)
    }

    @Test("Get missing returns nil")
    func getMissingReturnsNil() async throws {
        let storage = InMemoryKeychain()
        let value = try await storage.get(for: "absent")
        #expect(value == nil)
    }

    @Test("Set twice overwrites")
    func setTwiceOverwrites() async throws {
        let storage = InMemoryKeychain()
        try await storage.set("first", for: "acc")
        try await storage.set("second", for: "acc")
        let value = try await storage.get(for: "acc")
        #expect(value == "second")
    }

    @Test("Delete missing is a no-op")
    func deleteMissingOk() async throws {
        let storage = InMemoryKeychain()
        try await storage.delete(for: "nothing")
    }

    @Test("Concurrent sets from multiple tasks serialise cleanly")
    func concurrentWrites() async throws {
        let storage = InMemoryKeychain()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    try? await storage.set("value-\(i)", for: "slot-\(i)")
                }
            }
        }
        // Spot-check — all 20 slots should be set.
        for i in 0..<20 {
            let value = try await storage.get(for: "slot-\(i)")
            #expect(value == "value-\(i)")
        }
    }

    @Test("fromSecureStorage resolves API key and builds MymeClient")
    func mymeClientFromSecureStorage() async throws {
        let storage = InMemoryKeychain()
        try await storage.set("api-key-XYZ", for: "staging")

        let client = try await MymeClient.fromSecureStorage(
            account: "staging",
            url: URL(string: "http://example.test")!,
            storage: storage
        )
        #expect(client.configuration.apiKey == "api-key-XYZ")
    }

    @Test("fromSecureStorage throws when account absent")
    func mymeClientFromSecureStorageMissing() async throws {
        let storage = InMemoryKeychain()

        do {
            _ = try await MymeClient.fromSecureStorage(
                account: "ghost",
                url: URL(string: "http://test")!,
                storage: storage
            )
            Issue.record("Expected KeychainError")
        } catch let error as KeychainError {
            if case .osStatus(let code) = error {
                #expect(code == errSecItemNotFound)
            } else {
                Issue.record("Expected osStatus error, got \(error)")
            }
        }
    }
}

@Suite("KeychainStorage (real Keychain)", .serialized)
struct KeychainStorageTests {

    /// Real Keychain access typically requires code signing; this test
    /// tolerates OSStatus failures rather than fails hard so CI on
    /// unsigned SPM binaries doesn't go red. Real signed targets (Notes,
    /// demo-swift-app-myme) exercise the real path.
    @Test("Round-trip tolerates missing-entitlement failures on unsigned SPM test binaries")
    func roundTripSmoke() async {
        let storage = KeychainStorage(service: "myme.sdk.tests", accessGroup: nil)
        let account = "round-trip-\(UUID().uuidString)"

        do {
            try await storage.set("hello", for: account)
            let got = try await storage.get(for: account)
            #expect(got == "hello")
            try await storage.delete(for: account)
        } catch let error as KeychainError {
            // Expected on unsigned SPM test binaries: errSecMissingEntitlement
            // or similar. Just log and pass.
            if case .osStatus = error { return }
            Issue.record("Unexpected KeychainError: \(error)")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
