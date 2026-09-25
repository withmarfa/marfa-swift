import Foundation
import Security
import Testing

@testable import Marfa

@Suite struct ServerFromTheEnvironment {
    @Test func bothNamesSetAreTheServer() throws {
        let server = try Server.fromEnvironment(["MARFA_API_URL": "http://127.0.0.1:8787", "MARFA_API_KEY": "mk_k"])
        #expect(server == Server(url: try #require(URL(string: "http://127.0.0.1:8787")), key: "mk_k"))
    }

    @Test func eitherNameMissingOrEmptyIsNoServer() throws {
        #expect(try Server.fromEnvironment([:]) == nil)
        #expect(try Server.fromEnvironment(["MARFA_API_URL": "http://127.0.0.1:8787"]) == nil)
        #expect(try Server.fromEnvironment(["MARFA_API_KEY": "mk_k"]) == nil)
        #expect(try Server.fromEnvironment(["MARFA_API_URL": "", "MARFA_API_KEY": "mk_k"]) == nil)
        #expect(try Server.fromEnvironment(["MARFA_API_URL": "http://127.0.0.1:8787", "MARFA_API_KEY": ""]) == nil)
    }

    @Test func anAddressThatNamesNoServerIsRefusedRatherThanPassedOver() throws {
        for url in ["127.0.0.1:8787", "ftp://127.0.0.1", "http://", "not a url"] {
            #expect(throws: Server.EnvironmentError.notAServer(url)) {
                try Server.fromEnvironment(["MARFA_API_URL": url, "MARFA_API_KEY": "mk_k"])
            }
        }
    }
}

/// A keychain file of this test's own, discarded when it ends, with prompts refused for the whole process so
/// a keychain call that would wait for a person fails instead.
func isolatedKeychain() throws -> Keychain {
    refusePrompts
    return try Keychain.isolated()
}

private let refusePrompts: Void = {
    SecKeychainSetUserInteractionAllowed(false)
}()

@Suite(.timeLimit(.minutes(1)))
struct KeychainKeys {
    let service = "com.withmarfa.marfa-swift.tests"
    let account = "https://\(UUID().uuidString.lowercased()).invalid"

    @Test func savingAgainReplacesTheKey() throws {
        let keychain = try isolatedKeychain()
        defer { try? keychain.discard() }
        try keychain.save(key: "first", service: service, account: account)
        #expect(try keychain.key(service: service, account: account) == "first")
        try keychain.save(key: "second", service: service, account: account)
        #expect(try keychain.key(service: service, account: account) == "second")
    }

    @Test func aKeyNeverKeptIsNothing() throws {
        let keychain = try isolatedKeychain()
        defer { try? keychain.discard() }
        #expect(try keychain.key(service: service, account: "never") == nil)
        // The witness: a key kept under the same service is found.
        try keychain.save(key: "k", service: service, account: account)
        #expect(try keychain.key(service: service, account: account) == "k")
    }

    @Test func deletingAKeyNeverKeptIsNoError() throws {
        let keychain = try isolatedKeychain()
        defer { try? keychain.discard() }
        try keychain.delete(service: service, account: "never")
        // The witness: deleting a key kept removes it.
        try keychain.save(key: "k", service: service, account: account)
        try keychain.delete(service: service, account: account)
        #expect(try keychain.key(service: service, account: account) == nil)
    }

    @Test func aKeyKeptInAnIsolatedKeychainNeverReachesTheSystemOne() throws {
        let keychain = try isolatedKeychain()
        defer { try? keychain.discard() }
        try keychain.save(key: "k", service: service, account: account)
        // The witness: the isolated keychain holds it, asked the same way.
        #expect(try keychain.holds(service: service, account: account))
        #expect(try !Keychain.system.holds(service: service, account: account))
        #expect(try !Keychain.system.holds(service: service))
    }

    @Test func aDiscardedKeychainLeavesNoFile() throws {
        let keychain = try isolatedKeychain()
        let file = try #require(keychain.file)
        // The witness: the file is there until it is discarded.
        #expect(FileManager.default.fileExists(atPath: file.path))
        try keychain.discard()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
