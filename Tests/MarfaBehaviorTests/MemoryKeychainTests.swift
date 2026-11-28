#if DEBUG
import Foundation
import Marfa
import MarfaTesting
import Security
import Testing

@Suite struct MemoryKeychainBehavior {
    let service = "com.example.tests"
    let home = URL(string: "https://marfa.example")!

    @Test func savedKeyIsReadBackAndDeleted() throws {
        let memory = MemoryKeychain()
        try memory.keychain.save(key: "mk_a", service: service, account: "a")
        #expect(try memory.keychain.key(service: service, account: "a") == "mk_a")
        #expect(try memory.keychain.holds(service: service))
        #expect(try memory.keychain.holds(service: service, account: "a"))
        #expect(try !memory.keychain.holds(service: service, account: "b"))
        try memory.keychain.delete(service: service, account: "a")
        #expect(try memory.keychain.key(service: service, account: "a") == nil)
        try memory.keychain.delete(service: service, account: "a")
    }

    @Test func aReadOfNothingIsNil() throws {
        let memory = MemoryKeychain()
        #expect(try memory.keychain.key(service: service, account: "never") == nil)
        #expect(try !memory.keychain.holds(service: service))
    }

    @Test func savingAgainReplacesTheKey() throws {
        let memory = MemoryKeychain()
        try memory.keychain.save(key: "first", service: service, account: "a")
        try memory.keychain.save(key: "second", service: service, account: "a")
        #expect(try memory.keychain.key(service: service, account: "a") == "second")
    }

    @Test func eachKeychainIsAPlaceOfItsOwn() throws {
        let one = MemoryKeychain()
        let other = MemoryKeychain()
        try one.keychain.save(key: "mk_a", service: service, account: "a")
        #expect(try other.keychain.key(service: service, account: "a") == nil)
        #expect(one.keychain != other.keychain)
    }

    @Test func aKeyStoreRunsOnIt() throws {
        let memory = MemoryKeychain()
        let store = KeychainKeyStore(keychain: memory.keychain, service: service)
        #expect(try store.key(for: home) == nil)
        try store.save("mk_a", for: home)
        #expect(try store.key(for: URL(string: "HTTPS://MARFA.example:443/")!) == "mk_a")
        try store.delete(for: home)
        #expect(try store.key(for: home) == nil)
    }

    @Test func aScriptedReadFailureIsThrownWithItsStatusAndTheKeyStaysKept() throws {
        let memory = MemoryKeychain()
        let store = KeychainKeyStore(keychain: memory.keychain, service: service)
        try store.save("mk_a", for: home)
        memory.failReads(with: errSecInteractionNotAllowed)
        let error = #expect(throws: Keychain.Failure.self) { try store.key(for: home) }
        #expect(error?.status == errSecInteractionNotAllowed)
        memory.succeed()
        #expect(try store.key(for: home) == "mk_a", "a refused read lost the key")
    }

    @Test func aScriptedWriteFailureIsThrownAndNothingIsKept() throws {
        let memory = MemoryKeychain()
        let store = KeychainKeyStore(keychain: memory.keychain, service: service)
        memory.failWrites(with: errSecAuthFailed)
        let saved = #expect(throws: Keychain.Failure.self) { try store.save("mk_a", for: home) }
        #expect(saved?.status == errSecAuthFailed)
        #expect(throws: Keychain.Failure.self) { try store.delete(for: home) }
        #expect(try store.key(for: home) == nil, "reads are not refused")
        memory.succeed()
        #expect(try store.key(for: home) == nil, "a refused write kept the key")
    }
}

@Suite struct MemorySignInBehavior {
    let home = URL(string: "https://marfa.example")!

    @Test func aCredentialBuildsAServerAndReportsItsScopes() throws {
        let memory = MemoryKeychain()
        let credential = try memory.signIn(
            to: home, accessToken: "at-1", scopes: ["core.note:read", InstancePermission.keysManage.rawValue])
        #expect(credential.server == home)
        #expect(credential.scopes == ["core.note:read", "keys.manage"])
        #expect(credential.grants(.keysManage))
        #expect(!credential.grants(.webhooksManage))
        let server = try Server(url: home.appending(path: "some/path"), credential: credential)
        #expect(server.key == "at-1")
        #expect(server.credential == credential)
    }

    @Test func theAuthorizationReadsTheSameSignIn() throws {
        let memory = MemoryKeychain()
        let credential = try memory.signIn(to: home, service: "com.example.tests", scopes: ["core.note:read"])
        let authorization = try Authorization(
            server: home, client: .init(name: "Tests", scopes: []), keychain: memory.keychain,
            service: "com.example.tests")
        #expect(try authorization.credential() == credential)
        let other = try Authorization(
            server: home, client: .init(name: "Tests", scopes: []), keychain: memory.keychain, service: "another")
        #expect(try other.credential() == nil)
    }

    @Test func aSignInCarriesTheClientIDATestChooses() throws {
        let memory = MemoryKeychain()
        #expect(try memory.signIn(to: home).clientID == "marfa-testing")
        let chosen = try memory.signIn(to: home, service: "com.example.tests", clientID: "client-of-the-app")
        #expect(chosen.clientID == "client-of-the-app")
        let authorization = try Authorization(
            server: home, client: .init(name: "Tests", scopes: []), keychain: memory.keychain,
            service: "com.example.tests")
        #expect(try authorization.credential()?.clientID == "client-of-the-app")
    }

    @Test func aCredentialIsRefusedForAnotherServerAndForUserInfo() throws {
        let credential = try MemoryKeychain().signIn(to: home)
        #expect(throws: SignInError.otherServer) {
            try Server(url: URL(string: "https://elsewhere.example")!, credential: credential)
        }
        #expect(throws: SignInError.notAServer) {
            try Server(url: URL(string: "https://owner:hunter2@marfa.example")!, credential: credential)
        }
        #expect(throws: SignInError.notAServer) {
            try MemoryKeychain().signIn(to: URL(string: "https://owner@marfa.example")!)
        }
        #expect(throws: SignInError.notAServer) { try MemoryKeychain().signIn(to: URL(string: "ftp://marfa.example")!) }
    }

    @Test func aServerOpensOnlyWhileTheSignInIsKept() async throws {
        let memory = MemoryKeychain()
        let credential = try memory.signIn(to: home, service: "com.example.tests")
        let authorization = try Authorization(
            server: home, client: .init(name: "Tests", scopes: []), keychain: memory.keychain,
            service: "com.example.tests")
        _ = try await authorization.signOut()
        #expect(throws: SignInError.notSignedIn) { try Server(url: home, credential: credential) }
    }

    @Test func aRefusedAccessTokenWithNoRefreshTokenEndsTheSignInAsARealOneDoes() async throws {
        let memory = MemoryKeychain()
        let credential = try memory.signIn(to: home, accessToken: "at-1")
        let server = try Server(url: home, credential: credential)
        do {
            _ = try await server.renewedToken(refused: "at-1")
            Issue.record("a renewal with no refresh token answered a token")
        } catch {
            if case .signedOut = error {} else { Issue.record("expected signedOut, got \(error)") }
        }
        #expect(throws: SignInError.notSignedIn) { try Server(url: home, credential: credential) }
    }

    @Test func aRenewalWithARefreshTokenReachesNoNetworkAndKeepsTheSignIn() async throws {
        let endpoint = try await ConnectionCounter()
        let memory = MemoryKeychain()
        let credential = try memory.signIn(to: endpoint.url, accessToken: "at-1", refreshToken: "rt-1")
        let server = try Server(url: endpoint.url, credential: credential)
        do {
            _ = try await server.renewedToken(refused: "at-1")
            Issue.record("a renewal with no server answered a token")
        } catch {
            if case .network = error {} else { Issue.record("expected network, got \(error)") }
        }
        #expect(endpoint.connections == 0)
        #expect(try Server(url: endpoint.url, credential: credential).key == "at-1")
    }

    @Test func aRefusedAccessTokenAlreadyRenewedAnswersTheKeptOne() async throws {
        let memory = MemoryKeychain()
        let credential = try memory.signIn(to: home, accessToken: "at-2", refreshToken: "rt-1")
        let server = try Server(url: home, credential: credential)
        #expect(try await server.renewedToken(refused: "at-1") == "at-2")
    }

    @Test func aKeychainThatRefusesReadsMakesTheServerUnreadableNotSignedOut() throws {
        let memory = MemoryKeychain()
        let credential = try memory.signIn(to: home)
        memory.failReads(with: errSecInteractionNotAllowed)
        let error = #expect(throws: Keychain.Failure.self) { try Server(url: home, credential: credential) }
        #expect(error?.status == errSecInteractionNotAllowed)
    }
}
#endif
