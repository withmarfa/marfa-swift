import Foundation
import MarfaAPI
import Testing

@testable import Marfa

/// The owner's calls against a server of the test's own: one call for each area, then an owner sign-in that asks
/// for instance permissions by name.
///
/// The step-up test waits out the server's fifteen minutes after the sign-in, so it runs only where
/// `MARFA_LIVE_WAIT` is set.
@Suite(
    .serialized,
    .enabled(if: OwnServer.monorepo != nil, "set MARFA_MONOREPO to a marfa checkout whose server is built"))
struct LiveOwner {
    static let every = InstancePermission.allCases
    static let waits = ProcessInfo.processInfo.environment["MARFA_LIVE_WAIT"] != nil
    static let service = "com.withmarfa.marfa-swift.tests"

    @Test(.timeLimit(.minutes(10))) func everyAreaAnswersAnOwnerSignedInWithEveryPermission() async throws {
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

    @Test(.timeLimit(.minutes(10))) func aKeyIsToldWhichPermissionItLacks() async throws {
        let own = try await OwnServer.boot()
        do {
            let narrow = try await Self.keyWithoutInstancePermissions(own)
            let refused = await #expect(throws: MarfaError.self) { try await Client(narrow).listBackups() }
            #expect(refused?.code() == "forbidden", "\(String(describing: refused))")
        } catch {
            try await own.end()
            throw error
        }
        try await own.end()
    }

    @Test(.timeLimit(.minutes(5))) func theOwnersPasswordChangesAndChangesBack() async throws {
        let own = try await OwnServer.boot()
        do {
            try await Self.changePassword(own)
        } catch {
            try await own.end()
            throw error
        }
        try await own.end()
    }

    private static func changePassword(_ own: OwnServer) async throws {
        let original = try #require(own.owner?.password, "the server booted without an owner")
        let replaced = original + "-changed"
        let api = Client(own.server)
        let wrong = try await api.changePassword(from: "not the password", to: replaced)
        guard case .currentPasswordWrong = wrong else {
            Issue.record("expected currentPasswordWrong, got \(wrong)")
            return
        }
        let short = try await api.changePassword(from: original, to: "short")
        guard case .newPasswordRefused = short else {
            Issue.record("expected newPasswordRefused, got \(short)")
            return
        }
        #expect(try await api.changePassword(from: original, to: replaced) == .changed)
        // The old password no longer proves right, and the new one does: changing back needs the new one.
        let stale = try await api.changePassword(from: original, to: original)
        guard case .currentPasswordWrong = stale else {
            Issue.record("the replaced password still proved right: \(stale)")
            return
        }
        #expect(try await api.changePassword(from: replaced, to: original) == .changed)
        let narrow = try await Self.keyWithoutInstancePermissions(own)
        let refused = try await Client(narrow).changePassword(from: original, to: replaced)
        guard case .notPermitted(let scope, _) = refused else {
            Issue.record("expected notPermitted, got \(refused)")
            return
        }
        #expect(scope == "sign_ins.manage")
    }

    /// A key that may read notes and holds no instance permission, minted with the server's own key, which
    /// holds every one.
    private static func keyWithoutInstancePermissions(_ own: OwnServer) async throws -> Server {
        var request = URLRequest(url: own.url.appending(path: "keys"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(own.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "label": "Swift narrow key", "source": "swift-narrow", "type_permissions": ["core.note": "read"],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = try #require((response as? HTTPURLResponse)?.statusCode)
        try #require((200..<300).contains(status), "POST keys answered \(status)")
        let minted = try JSONDecoder().decode([String: JSONValue].self, from: data)
        return try Server(url: own.url, key: try #require(minted["key"]?.string))
    }

    @Test(
        .enabled(
            if: waits, "set MARFA_LIVE_WAIT to wait the fifteen minutes after the sign-in the server asks for"),
        .timeLimit(.minutes(20)))
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
        #expect(credential.scopes.contains("profile.username:write"))
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
        _ = try await api.listConnectors()
    }

    private static func authorization(_ own: OwnServer, _ keychain: Keychain, every: Bool = false) throws
        -> Authorization
    {
        try Authorization(
            server: own.url,
            client: Authorization.Client(
                name: "marfa-swift owner live tests",
                redirect: URL(string: "com.withmarfa.marfa-swift.tests:/signed-in"),
                scopes: every ? ["core.note:read", "profile.username:write"] : ["core.note:read"],
                permissions: every ? Self.every : [.configManage]),
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
        try await Task.sleep(for: .seconds(905))
        let before = kept
        let body = Operations.UpdateConfig.Input.Body.JsonPayload(allowPrivateAddresses: .value(true))
        let changed = try await api.updateConfig(body: .json(body)).ok.body.json
        #expect(changed.allowPrivateAddresses == true)
        let after = try #require(try authorization.place.read())
        #expect(after.accessToken != before.accessToken, "the owner was not asked to sign in again")
    }
}
