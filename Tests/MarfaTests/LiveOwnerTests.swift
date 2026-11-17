import Foundation
import MarfaAPI
import Testing

@testable import Marfa

/// The owner's calls against a server of the test's own: one call for each area, then an owner sign-in that asks
/// for owner permissions by name.
///
/// The step-up test waits out the server's five minutes after the sign-in, so it runs only where
/// `MARFA_LIVE_WAIT` is set.
@Suite(
    .serialized,
    .enabled(if: OwnServer.monorepo != nil, "set MARFA_MONOREPO to a marfa checkout whose server is built"),
    .timeLimit(.minutes(10)))
struct LiveOwner {
    static let every: [OwnerPermission] = [
        .backupsManage, .signInsManage, .configManage, .instanceMaintain, .instanceRead, .grantsManage, .keysManage,
        .itemsPurge, .profileEmailWrite,
    ]
    static let waits = ProcessInfo.processInfo.environment["MARFA_LIVE_WAIT"] != nil
    static let service = "com.withmarfa.marfa-swift.tests"

    @Test func everyAreaAnswersAnOwnerSignedInWithEveryPermission() async throws {
        let own = try await OwnServer.boot()
        do {
            try await inIsolatedKeychainAsync { keychain, _ async throws in
                try await Self.eachArea(own, keychain)
            }
        } catch {
            try await own.end()
            throw error
        }
        try await own.end()
    }

    @Test func aKeyIsToldWhichPermissionItLacks() async throws {
        let own = try await OwnServer.boot()
        let refused = await #expect(throws: MarfaError.self) { try await Client(own.server).listBackups() }
        #expect(refused?.code() == "forbidden", "\(String(describing: refused))")
        try await own.end()
    }

    @Test(
        .enabled(
            if: waits, "set MARFA_LIVE_WAIT to wait the five minutes after the sign-in the server asks for"),
        .timeLimit(.minutes(8)))
    func aWriteAfterTheSignInGrewOldAsksTheOwnerAgain() async throws {
        let own = try await OwnServer.boot()
        do {
            try await inIsolatedKeychainAsync { keychain, _ async throws in
                try await Self.stepUp(own, keychain)
            }
        } catch {
            try await own.end()
            throw error
        }
        try await own.end()
    }

    private static func eachArea(_ own: OwnServer, _ keychain: Keychain) async throws {
        let authorization = try authorization(own, keychain, every: true)
        let credential = try await authorization.signIn(browser: LiveSignIn.browserApproval(on: own))
        #expect(Set(every.map(\.rawValue)).isSubset(of: Set(credential.scopes)))
        let api = Client(try Server(url: own.url, credential: credential))
        _ = try await api.getConfig()
        _ = try await api.listSettings()
        // A server with nowhere to keep backups says so, in its own words.
        let none = await #expect(throws: MarfaError.self) { try await api.listBackups() }
        #expect(none?.server?.code == "no_backup_destination", "\(String(describing: none))")
        _ = try await api.listSignIns()
        _ = try await api.listOwnerPasskeys()
        _ = try await api.listAppGrants()
        _ = try await api.getProfile()
        _ = try await api.listAttention()
        _ = try await api.getUpdate()
        _ = try await api.listTrash()
    }

    private static func authorization(_ own: OwnServer, _ keychain: Keychain, every: Bool = false) throws
        -> Authorization
    {
        try Authorization(
            server: own.url,
            client: Authorization.Client(
                name: "marfa-swift owner live tests",
                redirect: URL(string: "com.withmarfa.marfa-swift.tests:/signed-in"),
                scopes: ["core.note:read"],
                ownerPermissions: every ? Self.every : [.configManage]),
            keychain: keychain, service: service)
    }

    private static func stepUp(_ own: OwnServer, _ keychain: Keychain) async throws {
        let authorization = try authorization(own, keychain)
        let credential = try await authorization.signIn(browser: LiveSignIn.browserApproval(on: own))
        let browser = LiveSignIn.browserApproval(on: own)
        let server = try Server(url: own.url, credential: credential).confirming(browser)
        let api = Client(server)
        _ = try await api.getConfig()
        let kept = try #require(try authorization.place.read())
        try await Task.sleep(for: .seconds(305))
        let before = kept
        let body = Operations.UpdateConfig.Input.Body.JsonPayload(allowPrivateAddresses: .value(true))
        let changed = try await api.updateConfig(body: .json(body)).ok.body.json
        #expect(changed.allowPrivateAddresses == true)
        let after = try #require(try authorization.place.read())
        #expect(after.accessToken != before.accessToken, "the owner was not asked to sign in again")
    }
}
