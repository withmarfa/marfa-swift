import Foundation
import Security
import Testing

@testable import Marfa

@Suite struct ServerFromTheEnvironment {
    @Test func bothNamesSetAreTheServer() throws {
        let server = try Server.fromEnvironment(["MARFA_API_URL": "http://127.0.0.1:8787", "MARFA_API_KEY": "mk_k"])
        #expect(server == Server(url: try #require(URL(string: "http://127.0.0.1:8787")), key: "mk_k"))
    }

    @Test func neitherNameSetIsNoServer() throws {
        #expect(try Server.fromEnvironment([:]) == nil)
        #expect(try Server.fromEnvironment(["MARFA_API_URL": "", "MARFA_API_KEY": ""]) == nil)
    }

    @Test func oneNameWithoutTheOtherIsRefusedRatherThanLeftToTheKeychain() throws {
        let url = "http://127.0.0.1:8787"
        #expect(throws: Server.EnvironmentError.incomplete(missing: "MARFA_API_KEY")) {
            try Server.fromEnvironment(["MARFA_API_URL": url])
        }
        #expect(throws: Server.EnvironmentError.incomplete(missing: "MARFA_API_KEY")) {
            try Server.fromEnvironment(["MARFA_API_URL": url, "MARFA_API_KEY": ""])
        }
        #expect(throws: Server.EnvironmentError.incomplete(missing: "MARFA_API_URL")) {
            try Server.fromEnvironment(["MARFA_API_KEY": "mk_k"])
        }
    }

    @Test func anAddressThatNamesNoServerIsRefusedWithoutRepeatingIt() throws {
        let refused = ["127.0.0.1:8787", "ftp://127.0.0.1", "http://", "http://:8787", "not a url", "http://u:p@h"]
        for url in refused {
            #expect(throws: Server.EnvironmentError.notAServer) {
                try Server.fromEnvironment(["MARFA_API_URL": url, "MARFA_API_KEY": "mk_k"])
            }
        }
        #expect(!Server.EnvironmentError.notAServer.description.contains("mk_"))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct KeychainKeys {
    /// CI reads this line to compare the login keychain under this service before and after the suite.
    let service = "com.withmarfa.marfa-swift.tests"
    let account = "https://\(UUID().uuidString.lowercased()).invalid"

    @Test func savingAgainReplacesTheKey() throws {
        try inIsolatedKeychain { keychain, _ in
            try keychain.save(key: "first", service: service, account: account)
            #expect(try keychain.key(service: service, account: account) == "first")
            try keychain.save(key: "second", service: service, account: account)
            #expect(try keychain.key(service: service, account: account) == "second")
        }
    }

    @Test func aKeyNeverKeptIsNothing() throws {
        try inIsolatedKeychain { keychain, _ in
            #expect(try keychain.key(service: service, account: "never") == nil)
            try keychain.save(key: "k", service: service, account: account)
            #expect(try keychain.key(service: service, account: account) == "k")
        }
    }

    @Test func deletingAKeyNeverKeptIsNoError() throws {
        try inIsolatedKeychain { keychain, _ in
            try keychain.delete(service: service, account: "never")
            try keychain.save(key: "k", service: service, account: account)
            try keychain.delete(service: service, account: account)
            #expect(try keychain.key(service: service, account: account) == nil)
        }
    }

    /// Reads the search list, never an item of the login keychain.
    @Test func anIsolatedKeychainIsOutsideTheSearchList() throws {
        try inIsolatedKeychain { keychain, file in
            try keychain.save(key: "k", service: service, account: account)
            #expect(try keychain.holds(service: service, account: account))
            let resolved = file.resolvingSymlinksInPath().path
            var list: CFArray?
            try #require(SecKeychainCopySearchList(&list) == errSecSuccess)
            let searched = try #require(list as? [SecKeychain]).map { searched -> String in
                var length = UInt32(PATH_MAX)
                var path = [CChar](repeating: 0, count: Int(length))
                guard SecKeychainGetPath(searched, &length, &path) == errSecSuccess else { return "" }
                return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
            }
            #expect(!searched.isEmpty)
            #expect(!searched.contains(resolved), "\(searched)")
        }
    }

    @Test func aKeychainThatLockedItselfIsUnlockedWithoutAskingAnyone() throws {
        try inIsolatedKeychain { keychain, file in
            try keychain.save(key: "k", service: service, account: account)
            var opened: SecKeychain?
            #expect(SecKeychainOpen(file.path, &opened) == errSecSuccess)
            #expect(SecKeychainLock(try #require(opened)) == errSecSuccess)
            var status = SecKeychainStatus()
            SecKeychainGetStatus(opened, &status)
            #expect(status & SecKeychainStatus(kSecUnlockStateStatus) == 0)
            #expect(try keychain.key(service: service, account: account) == "k")
        }
    }

    @Test func aDiscardedKeychainLeavesNothingBehind() throws {
        var folder: URL?
        try inIsolatedKeychain { _, file in
            folder = file.deletingLastPathComponent()
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(folder).path))
    }
}
