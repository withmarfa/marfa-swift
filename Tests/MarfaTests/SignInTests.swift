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

extension KeptSignIn {
    func with(accessToken: String) -> KeptSignIn {
        var changed = self
        changed.accessToken = accessToken
        return changed
    }
}

/// Keychain errors a test turns on for one account's lookups, as a keychain that fails for a moment does.
private final class KeychainFault: Sendable {
    private let left = Mutex(0)

    /// Fails the next `count` lookups.
    func fail(_ count: Int = .max) { left.withLock { $0 = count } }
    func stop() { left.withLock { $0 = 0 } }

    fileprivate func take() -> Bool {
        left.withLock { left in
            guard left > 0 else { return false }
            left -= 1
            return true
        }
    }

    /// `keychain`, the same place, failing lookups of `account` while the fault is on.
    ///
    /// Adding an item never fails.
    func on(_ keychain: Keychain, account: String) -> Keychain {
        Keychain(identity: keychain.identity) { query, forNewItem in
            if !forNewItem, query[kSecAttrAccount] as? String == account, self.take() {
                throw Keychain.Failure(status: errSecInteractionNotAllowed)
            }
            try keychain.narrow(&query, forNewItem)
        }
    }
}

/// Takes the lease on `place` as another process sharing its keychain would, sharing no lock of this one.
private func heldElsewhere(_ place: SignInPlace, _ transport: SignInTransport) async throws -> RenewalLease {
    let other = SignInPlace(
        keychain: Keychain(narrow: place.keychain.narrow), service: place.service, account: place.account)
    return try await background { try RenewalLease.take(other, transport) }
}

private let leaseHeldElsewhere = SignInError.unavailable(message: "another process is using the sign-in")

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
            case "/auth/oauth2/revoke":
                return .json(200, [:])
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

    @Test func anApprovalThatCannotBeKeptIsRevokedRatherThanLeftStanding() async throws {
        let server = deviceServer { _ in tokens("at-1", "rt-1") }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let transport = server.transport()
            let authorization = try Authorization(
                server: server.url, client: Authorization.Client(name: "Device", scopes: ["core.note:read"]),
                keychain: keychain, service: service, transport: transport)
            let started = try await authorization.startDeviceSignIn()
            let held = try await heldElsewhere(authorization.place, transport)
            defer { held.release() }
            await #expect(throws: leaseHeldElsewhere) { try await started.credential() }
            #expect(try authorization.place.read() == nil)
            let revoked = try #require(server.requests(to: "/auth/oauth2/revoke").first).form
            #expect(revoked == ["token": "rt-1", "token_type_hint": "refresh_token", "client_id": "client-1"])
        }
    }

    @Test func aServerOutOfReachOrFailingSlowsThePollingAndItKeepsAsking() async throws {
        let server = deviceServer { poll in
            switch poll {
            case 1: .failure(.notConnectedToInternet)
            case 2: oauthError("server_error", status: 503)
            case 3: .failure(.timedOut)
            case 4: oauthError("authorization_pending")
            default: tokens("at-1", "rt-1")
            }
        }
        let clock = TestClock()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: client, keychain: keychain, service: service,
                transport: server.transport(clock: clock))
            let started = try await authorization.startDeviceSignIn()
            _ = try await started.credential()
            // RFC 8628 section 3.5: the interval doubles on each failure to reach the server.
            #expect(clock.pauses == [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(40)])
            #expect(try authorization.place.read()?.refreshToken == "rt-1")
        }
    }

    @Test func aServerThatStaysOutOfReachIsAskedUntilTheCodeExpires() async throws {
        let server = deviceServer(expiresIn: 30) { _ in .failure(.cannotConnectToHost) }
        let clock = TestClock()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: client, keychain: keychain, service: service,
                transport: server.transport(clock: clock))
            let started = try await authorization.startDeviceSignIn()
            await #expect(throws: SignInError.expired) { try await started.credential() }
            #expect(clock.pauses == [.seconds(5), .seconds(10), .seconds(15)])
            #expect(server.requests(to: "/auth/oauth2/token").count == 3)
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

    /// The same keychain file as `keychain`, reached as another process reaches it: no lock of this process's
    /// renewals is shared with it.
    private func anotherProcess(_ keychain: Keychain, _ server: ScriptedAuthServer, _ transport: SignInTransport)
        throws -> Credential
    {
        let authorization = try Authorization(
            server: server.url, client: client, keychain: Keychain(narrow: keychain.narrow), service: service,
            transport: transport)
        return try #require(try authorization.credential())
    }

    @Test func aRenewalWhoseRequestOutlivesItsLeaseSpendsTheRefreshTokenOnce() async throws {
        let server = ScriptedAuthServer()
        // Longer than the lease's lifetime, so a lease that lapsed while its holder waited would be taken.
        marfa(server) { _ in .delayed(.milliseconds(1500), tokens("at-2", "rt-2")) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let transport = server.transport()
            let (authorization, holder) = try signedIn(server, keychain, transport: transport)
            let other = try anotherProcess(keychain, server, transport)
            await #expect {
                try await renew(holder, refused: "at-1")
            } throws: { error in
                guard case RenewalError.Unavailable = error else { return false }
                return true
            }
            #expect(try await renew(other, refused: "at-1") == "at-2")
            #expect(server.requests(to: "/auth/oauth2/token").map { $0.form["refresh_token"] } == ["rt-1"])
            #expect(try authorization.place.read()?.refreshToken == "rt-2")
        }
    }

    @Test func aRenewalThatGaveUpKeepsTheAnswerThatArrivesLate() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in .delayed(.milliseconds(800), tokens("at-2", "rt-2")) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, credential) = try signedIn(server, keychain, transport: server.transport())
            await #expect {
                try await renew(credential, refused: "at-1")
            } throws: { error in
                guard case RenewalError.Unavailable = error else { return false }
                return true
            }
            #expect(try authorization.place.read()?.refreshToken == "rt-1")
            try await eventually("the late answer is kept", within: 5) {
                (try? authorization.place.read()?.refreshToken) == "rt-2"
            }
            #expect(try authorization.place.read()?.accessToken == "at-2")
            try await eventually("the lease is let go", within: 5) {
                (try? keychain.label(service: service, account: authorization.place.leaseAccount)) == .some(nil)
            }
        }
    }

    @Test func aRenewalWritesNothingOverASignInThatChangedWhileItAsked() async throws {
        let renewedElsewhere = KeptSignIn(
            clientId: "client-1", grantTypes: ["authorization_code", "refresh_token"],
            redirect: client.redirect?.absoluteString, accessToken: "at-9", refreshToken: "rt-9", scope: nil,
            tokenEndpoint: "https://unused.example/token", revocationEndpoint: nil)
        // While the request is out: another process renews, signs out, or takes the lease.
        let changes: [(String, @Sendable (SignInPlace) throws -> Void)] = [
            ("renewed", { try $0.keep(renewedElsewhere) }),
            ("signed out", { try $0.drop() }),
            (
                "lease taken",
                { place in
                    try place.keychain.delete(service: place.service, account: place.leaseAccount)
                    _ = try place.keychain.add(label: "taken", service: place.service, account: place.leaseAccount)
                }
            ),
        ]
        for (change, apply) in changes {
            for reply in [tokens("at-2", "rt-2"), oauthError("invalid_grant")] {
                let server = ScriptedAuthServer()
                try await inIsolatedKeychainAsync { keychain, _ async throws in
                    let (authorization, credential) = try signedIn(server, keychain, transport: server.transport())
                    let place = authorization.place
                    marfa(server) { _ in
                        try? apply(place)
                        return reply
                    }
                    let original = try place.read()
                    var renewed: String?
                    var failure: (any Error)?
                    do { renewed = try await renew(credential, refused: "at-1") } catch { failure = error }
                    switch change {
                    case "signed out":
                        if case RenewalError.Ended? = failure as? RenewalError {
                        } else {
                            Issue.record(
                                "\(change): renewed \(String(describing: renewed)), \(String(describing: failure))")
                        }
                        #expect(try place.read() == nil)
                    case "renewed":
                        #expect(renewed == "at-9", "\(change)")
                        #expect(try place.read() == renewedElsewhere, "\(change)")
                    default:
                        // The refused token is never handed back as if it were renewed.
                        if case RenewalError.Unavailable? = failure as? RenewalError {
                        } else {
                            Issue.record(
                                "\(change): renewed \(String(describing: renewed)), \(String(describing: failure))")
                        }
                        #expect(try place.read() == original, "\(change)")
                    }
                    if change == "lease taken" {
                        #expect(try keychain.label(service: service, account: place.leaseAccount) == "taken")
                    }
                }
            }
        }
    }

    @Test func aKeychainErrorWhileTheLeaseIsMovedOnKeepsTheRenewedSignIn() async throws {
        let server = ScriptedAuthServer()
        let fault = KeychainFault()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            var transport = server.transport()
            transport.timeLimit = .seconds(3)
            transport.leaseLifetime = .seconds(3)
            let (authorization, _) = try signedIn(server, keychain, transport: transport)
            let place = authorization.place
            let faulty = try Authorization(
                server: server.url, client: client, keychain: fault.on(keychain, account: place.leaseAccount),
                service: service, transport: transport)
            let credential = try #require(try faulty.credential())
            // While the request is out, the lease's next move fails once; it outlasts a third of the lifetime.
            marfa(server) { _ in
                fault.fail(1)
                return .delayed(.milliseconds(1300), tokens("at-2", "rt-2"))
            }
            #expect(try await renew(credential, refused: "at-1") == "at-2")
            #expect(try place.read()?.refreshToken == "rt-2")
        }
    }

    @Test func aRenewalAnsweredAfterItsHeartbeatsFailedKeepsTheRenewedSignIn() async throws {
        let server = ScriptedAuthServer()
        let fault = KeychainFault()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            var transport = server.transport()
            transport.timeLimit = .seconds(5)
            transport.leaseLifetime = .seconds(3)
            let (authorization, _) = try signedIn(server, keychain, transport: transport)
            let place = authorization.place
            let faulty = try Authorization(
                server: server.url, client: client, keychain: fault.on(keychain, account: place.leaseAccount),
                service: service, transport: transport)
            let credential = try #require(try faulty.credential())
            // Both moves of the lapse while the request is out fail, and the answer comes with less than a third
            // of the lifetime left; the server has spent rt-1 by then.
            marfa(server) { _ in
                fault.fail()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.1) { fault.stop() }
                return .delayed(.milliseconds(2200), tokens("at-2", "rt-2"))
            }
            #expect(try await renew(credential, refused: "at-1") == "at-2")
            #expect(try place.read()?.refreshToken == "rt-2")
        }
    }

    /// Takes a lease and lets it lapse while every move of the lapse fails.
    ///
    /// The moves fail as when a heartbeat cannot run in time, and keep failing until `body` stops `fault`.
    private func lapsedLease(
        _ keychain: Keychain,
        _ body: (RenewalLease, SignInPlace, SignInTransport, KeychainFault) async throws -> Void
    ) async throws {
        let fault = KeychainFault()
        let transport = ScriptedAuthServer().transport()
        let account = "https://lease.example"
        let place = SignInPlace(
            keychain: fault.on(keychain, account: "\(account) renewing"), service: service, account: account)
        let lease = try await background { try RenewalLease.take(place, transport) }
        defer { lease.release() }
        #expect(try lease.whileHeld { true } == true)
        fault.fail()
        try await Task.sleep(for: transport.leaseLifetime + .milliseconds(300))
        let label = try #require(try keychain.label(service: service, account: place.leaseAccount))
        #expect(RenewalLease.lapsed(label, lifetime: transport.leaseLifetime))
        try await body(lease, place, transport, fault)
    }

    @Test func aHolderWhoseLapsedLeaseAnotherHolderTookWritesNothing() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            try await lapsedLease(keychain) { lease, place, transport, fault in
                let other = SignInPlace(
                    keychain: Keychain(narrow: keychain.narrow), service: place.service, account: place.account)
                let taken = try await background { try RenewalLease.take(other, transport) }
                defer { taken.release() }
                fault.stop()
                let label = try keychain.label(service: service, account: place.leaseAccount)
                #expect(try lease.whileHeld { true } == nil)
                #expect(try keychain.label(service: service, account: place.leaseAccount) == label)
                #expect(try taken.whileHeld { true } == true)
            }
        }
    }

    @Test func aHolderWhoseLapsedLeaseNobodyTookWritesAndHoldsItAgain() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            try await lapsedLease(keychain) { lease, place, transport, fault in
                fault.stop()
                #expect(try lease.whileHeld { true } == true)
                let label = try #require(try keychain.label(service: service, account: place.leaseAccount))
                #expect(!RenewalLease.lapsed(label, lifetime: transport.leaseLifetime))
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
            let boot = RenewalLease.bootSession
            let other = try anotherProcess(keychain, server, transport).place
            let held = try await background { try RenewalLease.take(other, transport) }
            await #expect {
                try await renew(credential, refused: "at-1")
            } throws: { error in
                guard case RenewalError.Unavailable = error else { return false }
                return true
            }
            #expect(server.requests(to: "/auth/oauth2/token").isEmpty)
            #expect(try held.whileHeld { true } == true)
            held.release()

            // Lapsed on the shared clock; written before a restart, whose clock has started again; further ahead
            // than any lease lasts, as one written before a restart whose boot could not be told apart; unreadable.
            for left in [
                "dead \(boot) \(RenewalLease.now() - 1_000_000_000)",
                "before-restart 00000000-0000-0000-0000-000000000000 \(RenewalLease.now() + 600_000_000_000)",
                "too-far-ahead \(boot) \(RenewalLease.now() + 600_000_000_000)",
                "unreadable",
            ] {
                try keychain.delete(service: service, account: place.leaseAccount)
                try authorization.place.keep(try #require(try authorization.place.read()).with(accessToken: "at-1"))
                #expect(try keychain.add(label: left, service: service, account: place.leaseAccount))
                #expect(try await renew(credential, refused: "at-1") == "at-2", "\(left)")
                #expect(try keychain.label(service: service, account: place.leaseAccount) == nil, "\(left)")
            }
        }
    }

    @Test func aLeaseLabelNamesThisBootAndALapseOnTheSharedClock() throws {
        let label = RenewalLease.label(lapsingIn: .seconds(60))
        let parts = label.split(separator: " ").map(String.init)
        #expect(parts.count == 3)
        #expect(UUID(uuidString: parts[1]) != nil)
        let lapses = try #require(UInt64(parts[2]))
        // The clock the lease's heartbeat runs on, which stops while the device sleeps, as the heartbeat does.
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        #expect(lapses > now + 59_000_000_000 && lapses <= now + 60_000_000_000)
        #expect(!RenewalLease.lapsed(label, lifetime: .seconds(60)))
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

    @Test func aSignOutThatCannotTakeTheLeaseSaysSoAndChangesNothing() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in .json(200, [:]) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let transport = server.transport()
            let (authorization, _) = try signedIn(server, keychain, transport: transport)
            let held = try await heldElsewhere(authorization.place, transport)
            defer { held.release() }
            await #expect(throws: leaseHeldElsewhere) { try await authorization.signOut() }
            #expect(try authorization.place.read()?.refreshToken == "rt-1")
            #expect(server.requests(to: "/auth/oauth2/revoke").isEmpty)
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
