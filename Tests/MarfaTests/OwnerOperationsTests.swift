import Foundation
import Synchronization
import Testing

@testable import Marfa
@testable import MarfaAPI

private let service = "com.withmarfa.marfa-swift.tests"
private let contract = ["X-Marfa-Contract": String(marfaContractVersion)]
private let jsonHeaders = contract.merging(["Content-Type": "application/json"]) { $1 }
private let client = Authorization.Client(
    name: "Owner tests", redirect: URL(string: "so.marfa.tests:/signed-in"), scopes: ["core.note:read"],
    ownerPermissions: [.backupsManage, .configManage])

private let tags: ScriptedAuthServer.Reply = .raw(
    200, Data(#"{"data": [{"tag": "reading", "count": 2}], "next_cursor": null}"#.utf8), headers: jsonHeaders)

private let challenge: ScriptedAuthServer.Reply = .json(
    401, ["error": ["code": "insufficient_user_authentication", "message": "sign in again"]],
    headers: contract.merging([
        "WWW-Authenticate": #"Bearer error="insufficient_user_authentication", max_age="300""#
    ]) { $1 })

private func refused(_ status: Int, _ code: String, details: [String: any Sendable]? = nil)
    -> ScriptedAuthServer.Reply
{
    var error: [String: any Sendable] = ["code": code, "message": "scripted \(code)"]
    if let details { error["details"] = details }
    return .json(status, ["error": error], headers: contract)
}

private func tokens(_ access: String) -> ScriptedAuthServer.Reply {
    .json(
        200,
        [
            "access_token": access, "refresh_token": "rt-\(access)", "token_type": "Bearer", "expires_in": 3600,
            "scope": "core.note:read backups.manage config.manage offline_access",
        ])
}

/// Answers discovery, registration and the token endpoint, and hands the rest to `rest`.
private func marfa(
    _ server: ScriptedAuthServer, _ rest: @escaping @Sendable (ScriptedAuthServer.Request) -> ScriptedAuthServer.Reply
) {
    let discovery = server.discovery()
    server.answer { request in
        switch request.path {
        case "/.well-known/oauth-authorization-server": discovery
        case "/oauth/register": .json(201, ["client_id": "client-1"])
        case "/oauth/token": tokens("at-2")
        case "/oauth/revoke": .json(200, [:])
        default: rest(request)
        }
    }
}

/// A browser that records the address it was sent to and approves at once, or does what `then` says.
private final class Sheet: Sendable {
    private let shown = Mutex<[URL]>([])
    var urls: [URL] { shown.withLock { $0 } }
    var count: Int { urls.count }

    func maxAge(_ index: Int = 0) -> String? {
        URLComponents(url: urls[index], resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "max_age" }?
            .value
    }

    func approve(cancel: Bool = false) -> @MainActor @Sendable (URL, String) async throws -> URL {
        { [self] url, _ in
            shown.withLock { $0.append(url) }
            if cancel { throw SignInError.canceled }
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
                $0.name == "state"
            }?.value
            return URL(string: "so.marfa.tests:/signed-in?code=the-code&state=\(state ?? "")")!
        }
    }
}

private func signedIn(_ scripted: ScriptedAuthServer, _ keychain: Keychain, _ sheet: Sheet?, cancel: Bool = false)
    throws -> Server
{
    let authorization = try Authorization(
        server: scripted.url, client: client, keychain: keychain, service: service, transport: scripted.transport())
    try authorization.place.keep(
        KeptSignIn(
            clientId: "client-1", grantTypes: ["authorization_code", "refresh_token"],
            redirect: client.redirect?.absoluteString, accessToken: "at-1", refreshToken: "rt-1",
            scope: "core.note:read backups.manage config.manage offline_access",
            tokenEndpoint: "\(scripted.origin)/oauth/token", revocationEndpoint: "\(scripted.origin)/oauth/revoke"))
    let server = try Server(url: scripted.url, credential: #require(try authorization.credential()))
    guard let sheet else { return server }
    return server.confirming(sheet.approve(cancel: cancel))
}

private func failure(_ call: () async throws -> some Any) async -> MarfaError? {
    do {
        _ = try await call()
        return nil
    } catch {
        return error as? MarfaError
    }
}

@Suite(.timeLimit(.minutes(1)))
struct OwnerOperationsTests {
    @Test func aChallengeSignsTheOwnerInAgainWithTheMaxAgeAndTheCallGoesOnceMore() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer()
            marfa(scripted) { $0.headers["Authorization"] == "Bearer at-2" ? tags : challenge }
            let sheet = Sheet()
            let api = Client(try signedIn(scripted, keychain, sheet), through: nil, timeout: .seconds(30))
            let page = try await api.listTags().ok.body.json
            #expect(page.data.map(\.tag) == ["reading"])
            #expect(sheet.count == 1 && sheet.maxAge() == "300")
            #expect(
                scripted.requests(to: "/tags").map { $0.headers["Authorization"] } == ["Bearer at-1", "Bearer at-2"])
            let authorize = try #require(sheet.urls.first)
            #expect(authorize.absoluteString.contains("scope=core.note:read%20backups.manage"))
        }
    }

    @Test func theNewSignInIsKeptForTheNextCall() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer()
            marfa(scripted) { $0.headers["Authorization"] == "Bearer at-2" ? tags : challenge }
            let server = try signedIn(scripted, keychain, Sheet())
            _ = try await Client(server, through: nil, timeout: .seconds(30)).listTags()
            #expect(try server.credential?.accessToken() == "at-2")
        }
    }

    @Test func aSecondChallengeIsAnErrorAndStartsNoSecondSheet() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer()
            marfa(scripted) { _ in challenge }
            let sheet = Sheet()
            let api = Client(try signedIn(scripted, keychain, sheet), through: nil, timeout: .seconds(30))
            let error = await failure { try await api.listTags() }
            guard case .confirmationRequired(let maxAge, _, _)? = error else {
                Issue.record("expected confirmationRequired, got \(String(describing: error))")
                return
            }
            #expect(maxAge == 300)
            #expect(sheet.count == 1)
            #expect(scripted.requests(to: "/tags").count == 2)
        }
    }

    @Test func aCanceledSheetIsCanceledAndTheCallIsNotSentAgain() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer()
            marfa(scripted) { _ in challenge }
            let api = Client(
                try signedIn(scripted, keychain, Sheet(), cancel: true), through: nil, timeout: .seconds(30))
            let error = await failure { try await api.listTags() }
            #expect(error?.code() == "canceled", "\(String(describing: error))")
            #expect(scripted.requests(to: "/tags").count == 1)
            #expect(scripted.requests(to: "/oauth/token").isEmpty)
        }
    }

    @Test func withNoWayToShowTheSheetTheChallengeIsTheError() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer()
            marfa(scripted) { _ in challenge }
            let api = Client(try signedIn(scripted, keychain, nil), through: nil, timeout: .seconds(30))
            let error = await failure { try await api.listTags() }
            #expect(error?.fixedText.type == "confirmation_required", "\(String(describing: error))")
            #expect(scripted.requests(to: "/tags").count == 1)
        }
    }

    @Test func aServerCallConfirmsTheSameWay() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer()
            marfa(scripted) {
                $0.headers["Authorization"] == "Bearer at-2"
                    ? .raw(200, Data(#"{"data": [], "next_cursor": null}"#.utf8), headers: jsonHeaders) : challenge
            }
            let sheet = Sheet()
            let page = try await signedIn(scripted, keychain, sheet).snapshots(ofItem: "i1")
            #expect(page.snapshots.isEmpty && sheet.maxAge() == "300")
        }
    }

    @Test func callsWaitingOnTheSameChallengeShareOneSheet() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer()
            marfa(scripted) { $0.headers["Authorization"] == "Bearer at-2" ? tags : challenge }
            let sheet = Sheet()
            let api = Client(try signedIn(scripted, keychain, sheet), through: nil, timeout: .seconds(30))
            async let first = api.listTags()
            async let second = api.listTags()
            _ = try await (first, second)
            #expect(sheet.count == 1)
        }
    }

    @Test func aKeyIsRefusedWithItsOwnErrorAndFixedText() async throws {
        let scripted = ScriptedAuthServer { _ in refused(403, "app_sign_in_required") }
        let api = Client(
            Server(url: scripted.url, key: "marfa_k1_test"), through: scripted.transport().session,
            timeout: .seconds(30))
        let error = await failure { try await api.listTags() }
        guard case .appSignInRequired(let message, _)? = error else {
            Issue.record("expected appSignInRequired, got \(String(describing: error))")
            return
        }
        #expect(message.contains("an app you signed in to"))
        #expect(!message.contains("scripted"))
        #expect(error?.fixedText.type == "app_sign_in_required" && error?.fixedText.code == "app_sign_in_required")
        #expect(scripted.requests.count == 1)
    }

    @Test func aSecretSettingIsWrittenAndReadBackOnlyAsSet() async throws {
        let scripted = ScriptedAuthServer { request in
            let answer = #"{"instance_id": "inst", "secrets_set": ["object_store_secret_access_key"]}"#
            return request.method == "GET" || request.method == "PATCH"
                ? .raw(200, Data(answer.utf8), headers: jsonHeaders) : .json(404, [:])
        }
        let api = Client(
            Server(url: scripted.url, key: "marfa_k1_test"), through: scripted.transport().session,
            timeout: .seconds(30))
        let stored = try await api.updateConfig(
            body: .json(.init(objectStoreSecretAccessKey: .value("hunter2")))
        ).ok.body.json
        let sent = try #require(scripted.requests(to: "/config").first)
        #expect(sent.json["object_store_secret_access_key"] as? String == "hunter2")
        #expect(stored.secretsSet == ["object_store_secret_access_key"])
        let read = try await api.getConfig().ok.body.json
        #expect(read.secretsSet == ["object_store_secret_access_key"])
        let text = String(decoding: try JSONEncoder().encode(read), as: UTF8.self)
        #expect(!text.contains("hunter2"))
    }

    @Test func anUpdateTheServerCannotMakeKeepsItsCodeAndTheStepToDoOnTheHost() async throws {
        for code in ["update_unavailable", "update_not_ready"] {
            let scripted = ScriptedAuthServer { _ in
                refused(409, code, details: ["step": "Run the installer on the host."])
            }
            let api = Client(
                Server(url: scripted.url, key: "marfa_k1_test"), through: scripted.transport().session,
                timeout: .seconds(30))
            let error = await failure { try await api.startUpdate() }
            guard case .server(let status, let got, _, let details, _)? = error else {
                Issue.record("expected server, got \(String(describing: error))")
                return
            }
            #expect(status == 409 && got == code)
            #expect(details == .object(["step": .string("Run the installer on the host.")]))
        }
    }

    @Test func movingTheSignInAddressIsCheckedThenConfirmedForTheOwner() async throws {
        let scripted = ScriptedAuthServer { request in
            if request.path == "/config/address-check" {
                return .raw(
                    200,
                    Data(
                        """
                        {"sign_in_address": "https://new.example", "addresses": ["https://new.example"],
                         "requires_confirmation": true, "consequences": [], "next_steps": [
                         {"code": "sign_in", "sentence": "Sign in.", "url": "https://new.example/auth/sign-in"}]}
                        """.utf8), headers: jsonHeaders)
            }
            return .raw(200, Data(#"{"instance_id": "inst"}"#.utf8), headers: jsonHeaders)
        }
        let api = Client(
            Server(url: scripted.url, key: "marfa_k1_test"), through: scripted.transport().session,
            timeout: .seconds(30))
        let change = AddressChange(signInAddress: .set("https://new.example"), addresses: .clear)
        let check = try await api.check(change)
        #expect(check.requiresConfirmation && check.nextSteps.map(\.code) == [.signIn])
        let checkSent = try #require(scripted.requests(to: "/config/address-check").first)
        #expect(checkSent.json["sign_in_address"] as? String == "https://new.example")
        #expect(checkSent.json["addresses"] is NSNull)
        #expect(checkSent.json["confirm_sign_in_address_change"] == nil)
        _ = try await api.apply(change, after: check, expecting: "inst")
        let sent = try #require(scripted.requests(to: "/config").first)
        #expect(sent.method == "PATCH" && sent.headers["X-Marfa-Instance-Id"] == "inst")
        #expect(sent.json["confirm_sign_in_address_change"] as? Bool == true)
        #expect(sent.json["sign_in_address"] as? String == "https://new.example")
    }

    @Test func aChangeThatNeedsNoConfirmationIsNotConfirmed() async throws {
        let scripted = ScriptedAuthServer { _ in
            .raw(200, Data(#"{"instance_id": "inst"}"#.utf8), headers: jsonHeaders)
        }
        let api = Client(
            Server(url: scripted.url, key: "marfa_k1_test"), through: scripted.transport().session,
            timeout: .seconds(30))
        let check = try JSONDecoder().decode(
            Components.Schemas.AddressCheck.self,
            from: Data(
                #"{"sign_in_address": "https://a.example", "addresses": [], "requires_confirmation": false, "consequences": [], "next_steps": []}"#
                    .utf8))
        _ = try await api.apply(AddressChange(addresses: .set(["https://a.example"])), after: check)
        let sent = try #require(scripted.requests(to: "/config").first)
        #expect(sent.json["confirm_sign_in_address_change"] == nil)
    }

    @Test func theChallengeNamesItsMaxAge() {
        #expect(maxAge(#"Bearer error="insufficient_user_authentication", max_age="300""#) == 300)
        #expect(maxAge(#"Bearer error="x", max_age=0"#) == 0)
        #expect(maxAge("Bearer") == nil)
        #expect(maxAge(nil) == nil)
    }

    @Test func ownerPermissionsAreAskedForByNameAndCheckedOnTheCredential() async throws {
        #expect(client.scopes == ["core.note:read", "backups.manage", "config.manage"])
        #expect(Set(OwnerPermission.allCases.map(\.rawValue)).contains("profile.email:write"))
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer()
            let credential = try #require(try signedIn(scripted, keychain, nil).credential)
            #expect(credential.grants(.backupsManage) && !credential.grants(.keysManage))
        }
    }
}
