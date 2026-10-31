import Foundation
import Security
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct KeychainKeyStoreBehavior {
    /// CI reads the service in `KeychainKeys` to compare the login keychain; this suite uses the same one.
    let service = "com.withmarfa.marfa-swift.tests"
    let address = URL(string: "https://\(UUID().uuidString.lowercased()).invalid")!

    @Test func noKeyIsNilAndASavedKeyIsReadBack() throws {
        try inIsolatedKeychain { keychain, _ in
            let store = KeychainKeyStore(keychain: keychain, service: service)
            #expect(try store.key(for: address) == nil)
            try store.save("mk_a", for: address)
            #expect(try store.key(for: address) == "mk_a")
            #expect(try store.key(for: URL(string: "https://other.invalid")!) == nil)
        }
    }

    @Test func savingAgainReplacesAndDeletingForgets() throws {
        try inIsolatedKeychain { keychain, _ in
            let store = KeychainKeyStore(keychain: keychain, service: service)
            try store.save("mk_a", for: address)
            try store.save("mk_b", for: address)
            #expect(try store.key(for: address) == "mk_b")
            try store.delete(for: address)
            #expect(try store.key(for: address) == nil)
            try store.delete(for: address)
        }
    }

    @Test func theAccountIsTheServerAddress() throws {
        try inIsolatedKeychain { keychain, _ in
            try KeychainKeyStore(keychain: keychain, service: service).save("mk_a", for: address)
            #expect(try keychain.key(service: service, account: address.absoluteString) == "mk_a")
        }
    }

    @Test func twoServicesKeepTheirOwnKeys() throws {
        try inIsolatedKeychain { keychain, _ in
            let installed = KeychainKeyStore(keychain: keychain, service: "\(service).installed")
            let debug = KeychainKeyStore(keychain: keychain, service: "\(service).debug")
            try installed.save("mk_a", for: address)
            #expect(try debug.key(for: address) == nil)
        }
    }

    @Test func theDefaultServiceIsNamedForTheBundle() {
        #expect(KeychainKeyStore.defaultService == "\(Bundle.main.bundleIdentifier ?? "com.withmarfa.marfa").marfa-key")
        #expect(KeychainKeyStore().service == KeychainKeyStore.defaultService)
    }

    /// The keychain is refused before any item is read, so this reaches no keychain at all.
    @Test func aKeychainThatCannotBeReadThrowsRatherThanReadingAsNone() throws {
        let refused = Keychain { _, _ in throw Keychain.Failure(status: errSecAuthFailed) }
        let store = KeychainKeyStore(keychain: refused, service: service)
        #expect(throws: Keychain.Failure.self) { try store.key(for: address) }
        #expect(throws: Keychain.Failure.self) { try store.save("mk_a", for: address) }
    }
}
