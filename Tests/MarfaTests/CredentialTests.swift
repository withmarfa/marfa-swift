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

/// Runs `body` with a keychain file of its own, discarded after it whether it passed or threw, with prompts
/// refused for the whole process so a keychain call that would wait for a person fails instead.
func inIsolatedKeychain(_ body: (Keychain) throws -> Void) throws {
    refusePrompts
    let keychain = try Keychain.isolated()
    do {
        try body(keychain)
    } catch {
        try? keychain.discard()
        throw error
    }
    try keychain.discard()
}

private let refusePrompts: Void = {
    SecKeychainSetUserInteractionAllowed(false)
}()

@Suite(.timeLimit(.minutes(1)))
struct KeychainKeys {
    /// The service CI lists in the login keychain before and after the suite, which must not change.
    let service = "com.withmarfa.marfa-swift.tests"
    let account = "https://\(UUID().uuidString.lowercased()).invalid"

    @Test func savingAgainReplacesTheKey() throws {
        try inIsolatedKeychain { keychain in
            try keychain.save(key: "first", service: service, account: account)
            #expect(try keychain.key(service: service, account: account) == "first")
            try keychain.save(key: "second", service: service, account: account)
            #expect(try keychain.key(service: service, account: account) == "second")
        }
    }

    @Test func aKeyNeverKeptIsNothing() throws {
        try inIsolatedKeychain { keychain in
            #expect(try keychain.key(service: service, account: "never") == nil)
            // The witness: a key kept under the same service is found.
            try keychain.save(key: "k", service: service, account: account)
            #expect(try keychain.key(service: service, account: account) == "k")
        }
    }

    @Test func deletingAKeyNeverKeptIsNoError() throws {
        try inIsolatedKeychain { keychain in
            try keychain.delete(service: service, account: "never")
            // The witness: deleting a key kept removes it.
            try keychain.save(key: "k", service: service, account: account)
            try keychain.delete(service: service, account: account)
            #expect(try keychain.key(service: service, account: account) == nil)
        }
    }

    @Test func aKeyKeptInAnIsolatedKeychainNeverReachesTheSystemOne() throws {
        try inIsolatedKeychain { keychain in
            try keychain.save(key: "k", service: service, account: account)
            // The witness: the isolated keychain holds it, asked the same way.
            #expect(try keychain.holds(service: service, account: account))
            #expect(try !Keychain.system.holds(service: service, account: account))
            #expect(try !Keychain.system.holds(service: service))
        }
    }

    @Test func aDiscardedKeychainLeavesNothingBehind() throws {
        var folder: URL?
        try inIsolatedKeychain { keychain in
            let file = try #require(keychain.file)
            folder = file.deletingLastPathComponent()
            // The witness: the file is there until it is discarded.
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(folder).path))
    }
}
