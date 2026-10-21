import CryptoKit
import Foundation
import MarfaCore
import Synchronization
import Testing

@testable import Marfa

private let service = "com.withmarfa.marfa-swift.tests"
private let client = Authorization.Client(
    name: "Sign-in tests", redirect: URL(string: "so.marfa.tests:/signed-in"), scopes: ["core.note:read"])

/// Answers discovery and registration as Marfa does, and hands every other request to `rest`.
private func marfa(
    _ server: ScriptedAuthServer, _ rest: @escaping @Sendable (ScriptedAuthServer.Request) -> ScriptedAuthServer.Reply
) {
    let discovery = server.discovery()
    server.answer { request in
        switch request.path {
        case "/.well-known/oauth-authorization-server/auth": discovery
        case "/auth/oauth2/register": .json(201, ["client_id": "client-1"])
        default: rest(request)
        }
    }
}

private func tokens(_ access: String, _ refresh: String) -> ScriptedAuthServer.Reply {
    .json(
        200,
        [
            "access_token": access, "refresh_token": refresh, "token_type": "Bearer", "expires_in": 3600,
            "scope": "core.note:read offline_access",
        ])
}

private func oauthError(_ code: String, status: Int = 400) -> ScriptedAuthServer.Reply {
    .json(status, ["error": code, "error_description": "scripted \(code)"])
}

/// Keeps a sign-in as a finished sign-in would, without the round trips.
private func signedIn(
    _ server: ScriptedAuthServer, _ keychain: Keychain, transport: SignInTransport, access: String = "at-1",
    refresh: String? = "rt-1"
) throws -> (Authorization, Credential) {
    let authorization = try Authorization(
        server: server.url, client: client, keychain: keychain, service: service, transport: transport)
    try authorization.place.keep(
        KeptSignIn(
            clientId: "client-1", grantTypes: ["authorization_code", "refresh_token"],
            redirect: client.redirect?.absoluteString, accessToken: access,
            refreshToken: refresh, scope: "core.note:read offline_access",
            tokenEndpoint: "\(server.origin)/auth/oauth2/token",
            revocationEndpoint: "\(server.origin)/auth/oauth2/revoke"))
    return (authorization, try #require(try authorization.credential()))
}

/// Runs `renew` off the main thread, as the core does.
private func renew(_ credential: Credential, refused: String) async throws -> String {
    let renewer = TokenRenewer(credential)
    return try await background { try renewer.renew(refused: refused) }
}

@Suite(.timeLimit(.minutes(1)))
struct BrowserSignIn {
    @Test func sendsAnS256ChallengeAndStateAndRedeemsTheCodeWithItsVerifier() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { request in
            request.path == "/auth/oauth2/token" ? tokens("at-1", "rt-1") : .json(404, [:])
        }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: client, keychain: keychain, service: service,
                transport: server.transport())
            let asked = Mutex<URL?>(nil)
            let credential = try await authorization.signIn { url, scheme in
                #expect(scheme == "so.marfa.tests")
                asked.withLock { $0 = url }
                let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "state" }?.value
                return URL(string: "so.marfa.tests:/signed-in?code=the-code&state=\(state ?? "")")!
            }

            let query = try #require(
                asked.withLock { $0 }.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
            func value(_ name: String) -> String? { query.queryItems?.first { $0.name == name }?.value }
            #expect(query.path == "/auth/oauth2/authorize")
            #expect(value("response_type") == "code")
            #expect(value("client_id") == "client-1")
            #expect(value("redirect_uri") == "so.marfa.tests:/signed-in")
            #expect(value("scope") == "core.note:read offline_access")
            #expect(value("code_challenge_method") == "S256")
            #expect((value("state") ?? "").count >= 43)

            let registered = try #require(server.requests(to: "/auth/oauth2/register").first).json
            #expect(registered["application_type"] as? String == "native")
            #expect(registered["token_endpoint_auth_method"] as? String == "none")
            // marfa lists a client that holds the device grant as a command-line tool.
            #expect(registered["grant_types"] as? [String] == ["authorization_code", "refresh_token"])
            #expect(registered["response_types"] as? [String] == ["code"])
            #expect(registered["redirect_uris"] as? [String] == ["so.marfa.tests:/signed-in"])

            let exchange = try #require(server.requests(to: "/auth/oauth2/token").first).form
            #expect(exchange["grant_type"] == "authorization_code")
            #expect(exchange["code"] == "the-code")
            #expect(exchange["client_id"] == "client-1")
            let verifier = try #require(exchange["code_verifier"])
            #expect(base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) == value("code_challenge"))

            #expect(credential.server == server.url)
            #expect(credential.scopes == ["core.note:read", "offline_access"])
            let kept = try #require(try authorization.place.read())
            #expect(kept.accessToken == "at-1")
            #expect(kept.refreshToken == "rt-1")
            #expect(!"\(credential)".contains("at-1"))
        }
    }

    @Test func aSignInReusesTheKeptRegistrationOnlyWhenItHoldsTheGrantTheFlowNeeds() async throws {
        let server = ScriptedAuthServer()
        let origin = server.origin
        marfa(server) { request in
            switch request.path {
            case "/auth/oauth2/token": tokens("at-1", "rt-1")
            case "/auth/device/code":
                .json(
                    200,
                    [
                        "device_code": "device-1", "user_code": "ABCD-EFGH",
                        "verification_uri": "\(origin)/auth/device",
                        "expires_in": 600, "interval": 5,
                    ])
            default: .json(404, [:])
            }
        }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: client, keychain: keychain, service: service,
                transport: server.transport())
            let approve: @MainActor @Sendable (URL, String) async throws -> URL = { url, _ in
                let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "state" }?.value
                return URL(string: "so.marfa.tests:/signed-in?code=the-code&state=\(state ?? "")")!
            }
            _ = try await authorization.signIn(browser: approve)
            _ = try await authorization.signIn(browser: approve)
            #expect(server.requests(to: "/auth/oauth2/register").count == 1)

            _ = try await authorization.startDeviceSignIn().credential()
            let registered = server.requests(to: "/auth/oauth2/register").map(\.json)
            #expect(registered.count == 2)
            #expect(registered.last?["grant_types"] as? [String] == [deviceCodeGrant, "refresh_token"])
            #expect(registered.last?["redirect_uris"] == nil)
            _ = try await authorization.startDeviceSignIn().credential()
            #expect(server.requests(to: "/auth/oauth2/register").count == 2)

            _ = try await authorization.signIn(browser: approve)
            #expect(server.requests(to: "/auth/oauth2/register").count == 3)
        }
    }

    @Test func anApprovalWithAnotherStateIsRefusedBeforeItsCodeIsRedeemed() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in tokens("at-1", "rt-1") }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: client, keychain: keychain, service: service,
                transport: server.transport())
            for returned in [
                "so.marfa.tests:/signed-in?code=planted&state=someone-elses",
                "so.marfa.tests:/signed-in?code=planted",
            ] {
                await #expect(throws: SignInError.stateMismatch) {
                    try await authorization.signIn { _, _ in URL(string: returned)! }
                }
            }
            #expect(server.requests(to: "/auth/oauth2/token").isEmpty)
            #expect(try authorization.credential() == nil)
        }
    }

    @Test func aDeclinedApprovalIsDenied() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in tokens("at-1", "rt-1") }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: client, keychain: keychain, service: service,
                transport: server.transport())
            await #expect(throws: SignInError.denied) {
                try await authorization.signIn { url, _ in
                    let state =
                        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                        .first { $0.name == "state" }?.value ?? ""
                    return URL(string: "so.marfa.tests:/signed-in?error=access_denied&state=\(state)")!
                }
            }
            #expect(server.requests(to: "/auth/oauth2/token").isEmpty)
        }
    }

    @Test func aServerThatNamesAnotherIssuerIsNotSignedInTo() async throws {
        let server = ScriptedAuthServer()
        let foreign = server.discovery(issuer: "https://elsewhere.example/auth")
        server.answer { _ in foreign }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: client, keychain: keychain, service: service,
                transport: server.transport())
            await #expect {
                try await authorization.signIn { url, _ in url }
            } throws: { error in
                guard case SignInError.unreadable = error else { return false }
                return true
            }
            #expect(server.requests(to: "/auth/oauth2/register").isEmpty)
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DeviceSignInPolling {
    private func deviceServer(
        expiresIn: Int = 600, _ polls: @escaping @Sendable (Int) -> ScriptedAuthServer.Reply
    ) -> ScriptedAuthServer {
        let server = ScriptedAuthServer()
        let count = Mutex(0)
        let origin = server.origin
        marfa(server) { request in
            switch request.path {
            case "/auth/device/code":
                return .json(
                    200,
                    [
                        "device_code": "device-1", "user_code": "ABCD-EFGH",
                        "verification_uri": "\(origin)/auth/device",
                        "verification_uri_complete": "\(origin)/auth/device?user_code=ABCD-EFGH",
                        "expires_in": expiresIn, "interval": 5,
                    ])
            case "/auth/oauth2/token":
                return polls(
                    count.withLock {
                        $0 += 1
                        return $0
                    })
            default:
                return .json(404, [:])
            }
        }
        return server
    }

    @Test func waitsAtTheIntervalAndSlowsByFiveSecondsOnSlowDown() async throws {
        let server = deviceServer { poll in
            switch poll {
            case 1: oauthError("authorization_pending")
            case 2: oauthError("slow_down")
            case 3: oauthError("authorization_pending")
            default: tokens("at-1", "rt-1")
            }
        }
        let clock = TestClock()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: Authorization.Client(name: "Device", scopes: ["core.note:read"]),
                keychain: keychain, service: service, transport: server.transport(clock: clock))
            let started = try await authorization.startDeviceSignIn()
            #expect(started.userCode == "ABCD-EFGH")
            #expect(started.verificationURL.absoluteString == "\(server.origin)/auth/device")
            #expect(started.verificationURLComplete?.query() == "user_code=ABCD-EFGH")
            #expect(started.expiresAt == clock.now.addingTimeInterval(600))

            let credential = try await started.credential()
            #expect(clock.pauses == [.seconds(5), .seconds(5), .seconds(10), .seconds(10)])
            let polls = server.requests(to: "/auth/oauth2/token").map(\.form)
            #expect(polls.count == 4)
            #expect(polls.allSatisfy { $0["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code" })
            #expect(polls.allSatisfy { $0["device_code"] == "device-1" && $0["client_id"] == "client-1" })
            #expect(try authorization.place.read()?.refreshToken == "rt-1")
            #expect(credential.server == server.url)

            let registered = try #require(server.requests(to: "/auth/oauth2/register").first).json
            #expect(registered["redirect_uris"] == nil)
            #expect(registered["grant_types"] as? [String] == [deviceCodeGrant, "refresh_token"])
        }
    }

    @Test func aDeclinedGrantIsDeniedAndAnExpiredOneExpired() async throws {
        for (code, expected) in [("access_denied", SignInError.denied), ("expired_token", .expired)] {
            let server = deviceServer { poll in
                poll == 1 ? oauthError("authorization_pending") : oauthError(code)
            }
            try await inIsolatedKeychainAsync { keychain, _ async throws in
                let authorization = try Authorization(
                    server: server.url, client: client, keychain: keychain, service: service,
                    transport: server.transport())
                let started = try await authorization.startDeviceSignIn()
                await #expect(throws: expected) { try await started.credential() }
                #expect(try authorization.place.read() == nil)
            }
        }
    }

    @Test func stopsAskingOnceTheCodeHasExpired() async throws {
        let server = deviceServer(expiresIn: 12) { _ in oauthError("authorization_pending") }
        let clock = TestClock()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: client, keychain: keychain, service: service,
                transport: server.transport(clock: clock))
            let started = try await authorization.startDeviceSignIn()
            await #expect(throws: SignInError.expired) { try await started.credential() }
            #expect(clock.pauses == [.seconds(5), .seconds(5), .seconds(2)])
            #expect(server.requests(to: "/auth/oauth2/token").count == 3)
        }
    }

    @Test func cancellingTheTaskStopsTheWait() async throws {
        let server = deviceServer { _ in oauthError("authorization_pending") }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            var transport = server.transport()
            transport.sleep = { try await Task.sleep(for: $0 * 1000) }
            let authorization = try Authorization(
                server: server.url, client: client, keychain: keychain, service: service, transport: transport)
            let started = try await authorization.startDeviceSignIn()
            let waiting = Task { try await started.credential() }
            waiting.cancel()
            await #expect(throws: CancellationError.self) { try await waiting.value }
            #expect(server.requests(to: "/auth/oauth2/token").isEmpty)
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct TokenRenewal {
    @Test func aRefusedTokenIsRenewedAndTheRotatedPairKeptBeforeItReturns() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in tokens("at-2", "rt-2") }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, credential) = try signedIn(server, keychain, transport: server.transport())
            #expect(try await renew(credential, refused: "at-1") == "at-2")
            let asked = try #require(server.requests(to: "/auth/oauth2/token").first).form
            #expect(asked == ["grant_type": "refresh_token", "refresh_token": "rt-1", "client_id": "client-1"])
            let kept = try #require(try authorization.place.read())
            #expect(kept.accessToken == "at-2")
            #expect(kept.refreshToken == "rt-2")
            #expect(try credential.accessToken() == "at-2")
        }
    }

    @Test func aTokenAlreadyRenewedIsReturnedWithoutAskingTheServer() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in tokens("at-3", "rt-3") }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (_, credential) = try signedIn(server, keychain, transport: server.transport(), access: "at-2")
            #expect(try await renew(credential, refused: "at-1") == "at-2")
            #expect(server.requests(to: "/auth/oauth2/token").isEmpty)
        }
    }

    @Test func renewalsAtOnceForOneSignInSpendTheRefreshTokenOnce() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return tokens("at-2", "rt-2")
        }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (_, credential) = try signedIn(server, keychain, transport: server.transport())
            // Separate renewers, as two copies or a copy and a folder of one sign-in hold.
            let renewed = try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<4 { group.addTask { try await renew(credential, refused: "at-1") } }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            #expect(renewed == ["at-2", "at-2", "at-2", "at-2"])
            #expect(server.requests(to: "/auth/oauth2/token").count == 1)
        }
    }

    @Test(arguments: ["invalid_grant", "invalid_client"])
    func anEndedGrantDeletesTheSignInAndEnds(code: String) async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in oauthError(code, status: code == "invalid_client" ? 401 : 400) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, credential) = try signedIn(server, keychain, transport: server.transport())
            await #expect {
                try await renew(credential, refused: "at-1")
            } throws: { error in
                guard case RenewalError.Ended(let message) = error else { return false }
                return !message.contains("rt-1") && !message.contains("at-1")
            }
            #expect(try authorization.place.read() == nil)
        }
    }

    @Test func aServerThatDoesNotAnswerInTimeIsUnavailableAndTheSignInKept() async throws {
        let replies: [ScriptedAuthServer.Reply] = [
            .silence, .failure(.notConnectedToInternet), oauthError("server_error", status: 503),
        ]
        for reply in replies {
            let server = ScriptedAuthServer()
            marfa(server) { _ in reply }
            try await inIsolatedKeychainAsync { keychain, _ async throws in
                let (authorization, credential) = try signedIn(server, keychain, transport: server.transport())
                await #expect {
                    try await renew(credential, refused: "at-1")
                } throws: { error in
                    guard case RenewalError.Unavailable = error else { return false }
                    return true
                }
                #expect(try authorization.place.read()?.refreshToken == "rt-1")
            }
        }
    }

    @Test func aRenewalOnTheMainThreadIsRefusedRatherThanBlockingIt() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in tokens("at-2", "rt-2") }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (_, credential) = try signedIn(server, keychain, transport: server.transport())
            let renewer = TokenRenewer(credential)
            await MainActor.run { () -> Void in
                #expect {
                    try renewer.renew(refused: "at-1")
                } throws: { error in
                    guard case RenewalError.Failed = error else { return false }
                    return true
                }
            }
            #expect(server.requests(to: "/auth/oauth2/token").isEmpty)
        }
    }

    @Test func aLeaseAnotherProcessHoldsIsWaitedOnAndALapsedOneTaken() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in tokens("at-2", "rt-2") }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let transport = server.transport()
            let (authorization, credential) = try signedIn(server, keychain, transport: transport)
            let place = authorization.place
            let lapses = Int64((Date().timeIntervalSince1970 + 600) * 1000)
            #expect(try keychain.add(label: "other \(lapses)", service: service, account: place.leaseAccount))
            await #expect {
                try await renew(credential, refused: "at-1")
            } throws: { error in
                guard case RenewalError.Unavailable = error else { return false }
                return true
            }
            #expect(server.requests(to: "/auth/oauth2/token").isEmpty)
            #expect(try keychain.label(service: service, account: place.leaseAccount) == "other \(lapses)")

            try keychain.delete(service: service, account: place.leaseAccount)
            let lapsed = Int64((Date().timeIntervalSince1970 - 1) * 1000)
            #expect(try keychain.add(label: "dead \(lapsed)", service: service, account: place.leaseAccount))
            #expect(try await renew(credential, refused: "at-1") == "at-2")
            #expect(try keychain.label(service: service, account: place.leaseAccount) == nil)
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SigningOut {
    @Test func deletesTheSignInThenRevokesTheRefreshToken() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in .json(200, [:]) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, _) = try signedIn(server, keychain, transport: server.transport())
            #expect(try await authorization.signOut())
            #expect(try authorization.place.read() == nil)
            let revoked = try #require(server.requests(to: "/auth/oauth2/revoke").first).form
            #expect(revoked == ["token": "rt-1", "token_type_hint": "refresh_token", "client_id": "client-1"])
        }
    }

    @Test func aRevocationTheServerDoesNotConfirmStillSignsOutHere() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in .failure(.notConnectedToInternet) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, _) = try signedIn(server, keychain, transport: server.transport())
            #expect(try await authorization.signOut() == false)
            #expect(try authorization.place.read() == nil)
            #expect(try await authorization.signOut() == false)
        }
    }

    @Test func aServerMadeFromASignInThatEndedIsNotSignedIn() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in .json(200, [:]) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, credential) = try signedIn(server, keychain, transport: server.transport())
            let made = try Server(url: server.url, credential: credential)
            #expect(made.credential == credential)
            #expect(!"\(made)".contains("at-1"))
            try await authorization.signOut()
            #expect(throws: SignInError.notSignedIn) { try Server(url: server.url, credential: credential) }
        }
    }

    @Test func aCopyOrFoldersOpenedAfterSignOutIsNotSignedInRatherThanSendingTheOldToken() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in .json(200, [:]) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, credential) = try signedIn(server, keychain, transport: server.transport())
            let made = try Server(url: server.url, credential: credential)
            try await authorization.signOut()
            let store = FileManager.default.temporaryDirectory.appending(path: "marfa-signed-out-\(UUID()).db")
            defer { try? FileManager.default.removeItem(at: store) }
            await #expect(throws: SignInError.notSignedIn) { try await WorkingCopy.open(store: store, server: made) }
            #if os(macOS)
            _ = FolderFixture.registry
            await #expect(throws: SignInError.notSignedIn) { try await Folders(server: made).list() }
            #endif
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct UntidyAddresses {
    @Test(arguments: ["marfa.example.com", "ftp://marfa.example.com", "https:///no-host", "file:///tmp/marfa"])
    func anAddressThatNamesNoServerIsRefused(address: String) throws {
        let url = try #require(URL(string: address))
        #expect(throws: SignInError.notAServer) {
            try Authorization(server: url, client: client, keychain: Keychain(), service: service)
        }
    }

    @Test func aCredentialIsRefusedOnAnotherServer() async throws {
        let server = ScriptedAuthServer()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (_, credential) = try signedIn(server, keychain, transport: server.transport())
            for other in ["https://elsewhere.example", "http://\(server.url.host() ?? "")", "\(server.origin):8443"] {
                #expect(throws: SignInError.otherServer) {
                    try Server(url: try #require(URL(string: other)), credential: credential)
                }
            }
            #expect(try Server(url: server.url.appending(path: "some/path"), credential: credential).url.host() != nil)
        }
    }

    @Test func aBrowserSignInWithoutARedirectIsRefusedBeforeAnyRequest() async throws {
        let server = ScriptedAuthServer()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: Authorization.Client(name: "Device", scopes: ["core.note:read"]),
                keychain: keychain, service: service, transport: server.transport())
            await #expect(throws: SignInError.noRedirect) {
                try await authorization.signIn { url, _ in url }
            }
            #expect(server.requests.isEmpty)
        }
    }
}
