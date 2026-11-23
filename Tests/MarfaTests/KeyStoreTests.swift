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

    @Test func oneServerWrittenSeveralWaysIsOneAccount() throws {
        try inIsolatedKeychain { keychain, _ in
            let store = KeychainKeyStore(keychain: keychain, service: service)
            let host = try #require(address.host())
            try store.save("mk_a", for: address)
            for spelling in ["https://\(host)/", "HTTPS://\(host.uppercased())", "https://\(host):443//"] {
                #expect(try store.key(for: #require(URL(string: spelling))) == "mk_a", "\(spelling)")
            }
            try store.delete(for: #require(URL(string: "https://\(host.uppercased())/")))
            #expect(try store.key(for: address) == nil)
        }
    }

    @Test(arguments: [
        ("https://a.example", "https://a.example"), ("https://a.example/", "https://a.example"),
        ("HTTPS://A.Example", "https://a.example"), ("https://a.example:443", "https://a.example"),
        ("http://a.example:80/", "http://a.example"), ("http://a.example:443", "http://a.example:443"),
        ("https://a.example:8443/marfa/", "https://a.example:8443/marfa"),
        ("https://a.example/Marfa", "https://a.example/Marfa"),
        ("https://owner@a.example", "https://a.example"),
        ("https://owner:hunter2@a.example:443/", "https://a.example"),
        ("https://my%40mail.example:p%3Aw%2Fd@a.example:8443/marfa/", "https://a.example:8443/marfa"),
    ])
    func theAccountIsTheAddressWrittenOneWay(address: String, account: String) throws {
        #expect(KeychainKeyStore.account(for: try #require(URL(string: address))) == account)
    }

    @Test func aPasswordInTheAddressIsNeverPartOfTheAccount() throws {
        let host = try #require(address.host())
        let account = KeychainKeyStore.account(for: try #require(URL(string: "https://owner:hunter2@\(host)")))
        #expect(!account.contains("hunter2") && !account.contains("owner") && !account.contains("@"))
    }

    @Test func twoServicesKeepTheirOwnKeys() throws {
        try inIsolatedKeychain { keychain, _ in
            let installed = KeychainKeyStore(keychain: keychain, service: "\(service).installed")
            let debug = KeychainKeyStore(keychain: keychain, service: "\(service).debug")
            try installed.save("mk_a", for: address)
            #expect(try debug.key(for: address) == nil)
        }
    }

    @Test func aBundleIdentifierNamesTheService() {
        #expect(
            KeychainKeyStore.service(bundleIdentifier: "com.example.tool", processName: "ignored")
                == "com.example.tool.marfa-key")
    }

    /// With the Mac app's bundle identifier the service is the app's, and with none it is not.
    @Test(arguments: [nil, ""] as [String?], ["marfa", "Marfa CLI", "so.marfa.swift"])
    func aMissingBundleIdentifierUsesTheProcessName(bundleIdentifier: String?, processName: String) {
        let appService = KeychainKeyStore.service(bundleIdentifier: "com.withmarfa.marfa", processName: processName)
        #expect(appService == "com.withmarfa.marfa.marfa-key")
        let service = KeychainKeyStore.service(bundleIdentifier: bundleIdentifier, processName: processName)
        #expect(service == "so.marfa.swift.\(processName).marfa-key")
        #expect(service != appService)
    }

    @Test func theDefaultServiceFollowsThisProcess() {
        #expect(
            KeychainKeyStore.defaultService
                == KeychainKeyStore.service(
                    bundleIdentifier: Bundle.main.bundleIdentifier,
                    processName: ProcessInfo.processInfo.processName))
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
