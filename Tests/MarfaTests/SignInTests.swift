import CryptoKit
import Foundation
import MarfaCore
import MarfaTypes
import Synchronization
import Testing

@testable import Marfa

private let service = "com.withmarfa.marfa-swift.tests"
private let client = Authorization.Client(
    name: "Sign-in tests", redirect: URL(string: "so.marfa.tests:/signed-in"), scopes: ["core.note:read"])

/// Answers discovery and registration as Marfa does, and hands every other request to `rest`.
private func marfa(
    _ server: ScriptedAuthServer, issParameter: Bool? = nil,
    _ rest: @escaping @Sendable (ScriptedAuthServer.Request) -> ScriptedAuthServer.Reply
) {
    let discovery = server.discovery(issParameter: issParameter)
    server.answer { request in
        switch request.path {
        case "/.well-known/oauth-authorization-server": discovery
        case "/oauth/register": .json(201, ["client_id": "client-1"])
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
            tokenEndpoint: "\(server.origin)/oauth/token",
            revocationEndpoint: "\(server.origin)/oauth/revoke"))
    return (authorization, try #require(try authorization.credential()))
}

extension SignInTransport {
    func with(leaseLifetime: Duration) -> SignInTransport {
        var changed = self
        changed.leaseLifetime = leaseLifetime
        return changed
    }
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
    private let counts = Mutex((left: 0, failed: 0))

    /// Fails the next `count` lookups.
    func fail(_ count: Int = .max) { counts.withLock { $0.left = count } }
    func stop() { counts.withLock { $0.left = 0 } }

    /// How many lookups have failed so far.
    var failed: Int { counts.withLock { $0.failed } }

    fileprivate func take() -> Bool {
        counts.withLock { counts in
            guard counts.left > 0 else { return false }
            counts.left -= 1
            counts.failed += 1
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
///
/// It stays held for as long as the test runs, since a test's leases lapse only when the test moves their clock.
private func heldElsewhere(_ place: SignInPlace, _ transport: SignInTransport) async throws -> RenewalLease {
    let other = SignInPlace(
        keychain: Keychain(narrow: place.keychain.narrow), service: place.service, account: place.account)
    return try await background { try RenewalLease.take(other, transport) }
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
            request.path == "/oauth/token" ? tokens("at-1", "rt-1") : .json(404, [:])
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
            #expect(query.path == "/oauth/authorize")
            #expect(value("response_type") == "code")
            #expect(value("client_id") == "client-1")
            #expect(value("redirect_uri") == "so.marfa.tests:/signed-in")
            #expect(value("scope") == "core.note:read offline_access")
            #expect(value("code_challenge_method") == "S256")
            #expect((value("state") ?? "").count >= 43)

            let registered = try #require(server.requests(to: "/oauth/register").first).json
            #expect(registered["application_type"] as? String == "native")
            #expect(registered["token_endpoint_auth_method"] as? String == "none")
            // marfa lists a client that holds the device grant as a command-line tool.
            #expect(registered["grant_types"] as? [String] == ["authorization_code", "refresh_token"])
            #expect(registered["response_types"] as? [String] == ["code"])
            #expect(registered["redirect_uris"] as? [String] == ["so.marfa.tests:/signed-in"])

            let exchange = try #require(server.requests(to: "/oauth/token").first).form
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

    @Test func aSignInRegistersAClientOfItsOwnAndOnlyAConfirmationReusesTheKeptOneItsGrantAllows() async throws {
        let server = ScriptedAuthServer()
        let origin = server.origin
        marfa(server) { request in
            switch request.path {
            case "/oauth/token": tokens("at-1", "rt-1")
            case "/oauth/device-authorization":
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
            #expect(server.requests(to: "/oauth/register").count == 2)

            // A confirmation names the grant it confirms, so it reuses the kept client.
            _ = try await authorization.signIn(maxAge: 0, browser: approve)
            #expect(server.requests(to: "/oauth/register").count == 2)

            _ = try await authorization.startDeviceSignIn().credential()
            let registered = server.requests(to: "/oauth/register").map(\.json)
            #expect(registered.count == 3)
            #expect(registered.last?["grant_types"] as? [String] == [deviceCodeGrant, "refresh_token"])
            #expect(registered.last?["redirect_uris"] == nil)
            _ = try await authorization.startDeviceSignIn().credential()
            #expect(server.requests(to: "/oauth/register").count == 4)

            // The kept client holds the device grant, not the one a browser confirmation needs.
            _ = try await authorization.signIn(maxAge: 0, browser: approve)
            #expect(server.requests(to: "/oauth/register").count == 5)
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
            #expect(server.requests(to: "/oauth/token").isEmpty)
            #expect(try authorization.credential() == nil)
        }
    }

    /// The address the browser returns to: `state` as the authorization address carried it, and `iss` when given.
    private static func returned(
        to authorize: URL, _ fields: [(String, String)], iss: String?
    ) -> URL {
        let state =
            URLComponents(url: authorize, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "state" }?.value ?? ""
        var answer = URLComponents(string: "so.marfa.tests:/signed-in") ?? URLComponents()
        answer.queryItems =
            fields.map { URLQueryItem(name: $0.0, value: $0.1) } + [URLQueryItem(name: "state", value: state)]
            + (iss.map { [URLQueryItem(name: "iss", value: $0)] } ?? [])
        return answer.url ?? authorize
    }

    @Test func anApprovalWithTheServersIssuerIsRedeemed() async throws {
        let server = ScriptedAuthServer()
        marfa(server, issParameter: true) { _ in tokens("at-1", "rt-1") }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: client, keychain: keychain, service: service,
                transport: server.transport())
            _ = try await authorization.signIn { url, _ in
                Self.returned(to: url, [("code", "the-code")], iss: server.origin)
            }
            #expect(server.requests(to: "/oauth/token").count == 1)
            #expect(try authorization.credential() != nil)
        }
    }

    @Test(arguments: [
        "https://elsewhere.example", "", "ISSUER/",
    ])
    func anApprovalWithAnotherIssuerIsRefusedBeforeItsCodeIsRedeemed(other: String) async throws {
        for supported in [true, nil] as [Bool?] {
            let server = ScriptedAuthServer()
            marfa(server, issParameter: supported) { _ in tokens("at-1", "rt-1") }
            try await inIsolatedKeychainAsync { keychain, _ async throws in
                let authorization = try Authorization(
                    server: server.url, client: client, keychain: keychain, service: service,
                    transport: server.transport())
                let iss = other == "ISSUER/" ? server.origin + "/" : other
                await #expect(throws: SignInError.issuerMismatch) {
                    try await authorization.signIn { url, _ in
                        Self.returned(to: url, [("code", "planted")], iss: iss)
                    }
                }
                #expect(server.requests(to: "/oauth/token").isEmpty)
                #expect(try authorization.credential() == nil)
            }
        }
    }

    @Test func anApprovalWithNoIssuerIsRefusedWhenTheServerSaysItSendsOne() async throws {
        let server = ScriptedAuthServer()
        marfa(server, issParameter: true) { _ in tokens("at-1", "rt-1") }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: client, keychain: keychain, service: service,
                transport: server.transport())
            await #expect(throws: SignInError.issuerMismatch) {
                try await authorization.signIn { url, _ in Self.returned(to: url, [("code", "planted")], iss: nil) }
            }
            #expect(server.requests(to: "/oauth/token").isEmpty)
        }
    }

    @Test(arguments: [false, nil] as [Bool?])
    func anApprovalWithNoIssuerIsRedeemedWhenTheServerDoesNotSayItSendsOne(supported: Bool?) async throws {
        let server = ScriptedAuthServer()
        marfa(server, issParameter: supported) { _ in tokens("at-1", "rt-1") }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: client, keychain: keychain, service: service,
                transport: server.transport())
            _ = try await authorization.signIn { url, _ in Self.returned(to: url, [("code", "the-code")], iss: nil) }
            #expect(server.requests(to: "/oauth/token").count == 1)
        }
    }

    @Test func aRefusalFromAnotherIssuerIsNotTakenForTheServersOwn() async throws {
        let server = ScriptedAuthServer()
        marfa(server, issParameter: true) { _ in tokens("at-1", "rt-1") }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: client, keychain: keychain, service: service,
                transport: server.transport())
            await #expect(throws: SignInError.issuerMismatch) {
                try await authorization.signIn { url, _ in
                    Self.returned(to: url, [("error", "access_denied")], iss: "https://elsewhere.example")
                }
            }
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
            #expect(server.requests(to: "/oauth/token").isEmpty)
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
            #expect(server.requests(to: "/oauth/register").isEmpty)
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DeviceSignInPolling {
    private func deviceServer(
        expiresIn: Double = 600, _ polls: @escaping @Sendable (Int) -> ScriptedAuthServer.Reply
    ) -> ScriptedAuthServer {
        let server = ScriptedAuthServer()
        let count = Mutex(0)
        let origin = server.origin
        marfa(server) { request in
            switch request.path {
            case "/oauth/device-authorization":
                return .json(
                    200,
                    [
                        "device_code": "device-1", "user_code": "ABCD-EFGH",
                        "verification_uri": "\(origin)/auth/device",
                        "verification_uri_complete": "\(origin)/auth/device?user_code=ABCD-EFGH",
                        "expires_in": expiresIn, "interval": 5,
                    ])
            case "/oauth/revoke":
                return .json(200, [:])
            case "/oauth/token":
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
            let polls = server.requests(to: "/oauth/token").map(\.form)
            #expect(polls.count == 4)
            #expect(polls.allSatisfy { $0["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code" })
            #expect(polls.allSatisfy { $0["device_code"] == "device-1" && $0["client_id"] == "client-1" })
            #expect(try authorization.place.read()?.refreshToken == "rt-1")
            #expect(credential.server == server.url)

            let registered = try #require(server.requests(to: "/oauth/register").first).json
            #expect(registered["redirect_uris"] == nil)
            #expect(registered["grant_types"] as? [String] == [deviceCodeGrant, "refresh_token"])
        }
    }

    @Test(arguments: [1e20, -5, 1e300, 100_000])
    func aDeviceCodeWhoseLifetimeIsNegativeOrAbsurdIsUnreadableRatherThanTrapping(expiresIn: Double) async throws {
        let server = deviceServer(expiresIn: expiresIn) { _ in tokens("at-1", "rt-1") }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: Authorization.Client(name: "Device", scopes: ["core.note:read"]),
                keychain: keychain, service: service, transport: server.transport())
            await #expect {
                try await authorization.startDeviceSignIn()
            } throws: { error in
                guard case SignInError.unreadable = error else { return false }
                return true
            }
            #expect(try authorization.place.read() == nil)
        }
    }

    @Test func anApprovalThatCannotBeKeptIsRevokedRatherThanLeftStanding() async throws {
        let server = deviceServer { _ in tokens("at-1", "rt-1") }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            var transport = server.transport()
            transport.leaseLifetime = .seconds(1)
            let authorization = try Authorization(
                server: server.url, client: Authorization.Client(name: "Device", scopes: ["core.note:read"]),
                keychain: keychain, service: service, transport: transport)
            let started = try await authorization.startDeviceSignIn()
            let held = try await heldElsewhere(authorization.place, transport)
            defer { held.release() }
            await #expect(throws: SignInError.heldElsewhere) { try await started.credential() }
            #expect(try authorization.place.read() == nil)
            let revoked = try #require(server.requests(to: "/oauth/revoke").first).form
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
            #expect(server.requests(to: "/oauth/token").count == 3)
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
            #expect(server.requests(to: "/oauth/token").count == 3)
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
            #expect(server.requests(to: "/oauth/token").isEmpty)
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
            let asked = try #require(server.requests(to: "/oauth/token").first).form
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
            #expect(server.requests(to: "/oauth/token").isEmpty)
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
            #expect(server.requests(to: "/oauth/token").count == 1)
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

    /// Keeps a sign-in made against the earlier token endpoint, which the server no longer serves.
    private func signedInAtEarlierEndpoint(
        _ server: ScriptedAuthServer, _ keychain: Keychain
    ) throws -> (Authorization, Credential) {
        let (authorization, _) = try signedIn(server, keychain, transport: server.transport())
        var kept = try #require(try authorization.place.read())
        kept.tokenEndpoint = "\(server.origin)/auth/oauth2/token"
        kept.revocationEndpoint = "\(server.origin)/auth/oauth2/revoke"
        try authorization.place.keep(kept)
        return (authorization, try #require(try authorization.credential()))
    }

    @Test(arguments: [404, 410])
    func aTokenEndpointTheServerNoLongerHasIsReadAgainAndTheRenewalSentToTheEndpointItNowAdvertises(
        status: Int
    ) async throws {
        let server = ScriptedAuthServer()
        marfa(server) { request in
            request.path == "/oauth/token" ? tokens("at-2", "rt-2") : .json(status, [:])
        }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, credential) = try signedInAtEarlierEndpoint(server, keychain)
            #expect(try await renew(credential, refused: "at-1") == "at-2")
            let asked = ["/auth/oauth2/token", "/.well-known/oauth-authorization-server", "/oauth/token"]
            #expect(server.requests.map(\.path) == asked)
            let sent = try #require(server.requests(to: "/oauth/token").first).form
            #expect(sent == ["grant_type": "refresh_token", "refresh_token": "rt-1", "client_id": "client-1"])
            let kept = try #require(try authorization.place.read())
            #expect(kept.accessToken == "at-2")
            #expect(kept.refreshToken == "rt-2")
            #expect(kept.tokenEndpoint == "\(server.origin)/oauth/token")
            #expect(kept.revocationEndpoint == "\(server.origin)/oauth/revoke")
            // The next renewal goes to the endpoint now kept and reads the metadata no more.
            server.answer { _ in tokens("at-3", "rt-3") }
            #expect(try await renew(credential, refused: "at-2") == "at-3")
            #expect(server.requests(to: "/auth/oauth2/token").count == 1)
            #expect(server.requests(to: "/.well-known/oauth-authorization-server").count == 1)
        }
    }

    @Test func aTokenEndpointTheServerNoLongerHasAndNoOtherEndsTheSignIn() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in .json(404, ["error": ["code": "not_found", "message": "not found"]]) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, credential) = try signedInAtEarlierEndpoint(server, keychain)
            await #expect {
                try await renew(credential, refused: "at-1")
            } throws: { error in
                guard case RenewalError.Ended(let message) = error else { return false }
                return !message.contains("rt-1") && !message.contains("at-1")
            }
            #expect(try authorization.place.read() == nil)
            // The refresh token went to the earlier endpoint and to the advertised one, once each.
            #expect(server.requests(to: "/auth/oauth2/token").count == 1)
            #expect(server.requests(to: "/oauth/token").count == 1)
        }
    }

    @Test func aRefusalThatIsAnOAuthErrorIsNeverTakenForAMissingEndpoint() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in oauthError("invalid_request", status: 404) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, credential) = try signedInAtEarlierEndpoint(server, keychain)
            await #expect {
                try await renew(credential, refused: "at-1")
            } throws: { error in
                guard case RenewalError.Failed = error else { return false }
                return true
            }
            #expect(server.requests(to: "/.well-known/oauth-authorization-server").isEmpty)
            #expect(try authorization.place.read()?.refreshToken == "rt-1")
        }
    }

    @Test func aRetryTheAdvertisedEndpointRefusesWithAnOAuthErrorKeepsTheSignIn() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { request in
            request.path == "/oauth/token" ? oauthError("invalid_request") : .json(404, [:])
        }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, credential) = try signedInAtEarlierEndpoint(server, keychain)
            await #expect {
                try await renew(credential, refused: "at-1")
            } throws: { error in
                guard case RenewalError.Failed = error else { return false }
                return true
            }
            let kept = try #require(try authorization.place.read())
            #expect(kept.refreshToken == "rt-1")
            #expect(kept.tokenEndpoint == "\(server.origin)/auth/oauth2/token")
        }
    }

    @Test(arguments: [ScriptedAuthServer.Reply.json(503, [:]), .failure(.notConnectedToInternet)])
    func aServerThatCannotGiveItsMetadataLeavesTheSignInKeptAndUnavailable(
        metadata: ScriptedAuthServer.Reply
    ) async throws {
        let server = ScriptedAuthServer()
        server.answer { request in
            request.path == "/.well-known/oauth-authorization-server" ? metadata : .json(404, [:])
        }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, credential) = try signedInAtEarlierEndpoint(server, keychain)
            await #expect {
                try await renew(credential, refused: "at-1")
            } throws: { error in
                guard case RenewalError.Unavailable = error else { return false }
                return true
            }
            #expect(try authorization.place.read()?.refreshToken == "rt-1")
            #expect(server.requests(to: "/oauth/token").isEmpty)
        }
    }

    @Test func aRenewalThatLostItsLeaseWhileReadingTheMetadataSendsNothingAndAnswersTheNewerToken() async throws {
        let server = ScriptedAuthServer()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, credential) = try signedInAtEarlierEndpoint(server, keychain)
            let place = authorization.place
            let metadata = server.discovery()
            server.answer { request in
                guard request.path == "/.well-known/oauth-authorization-server" else { return .json(404, [:]) }
                // Another process takes the lease and rotates the tokens while the metadata loads.
                var rotated = try! place.read()!
                rotated.accessToken = "at-other"
                rotated.refreshToken = "rt-other"
                try! place.keep(rotated)
                try! keychain.delete(service: place.service, account: place.leaseAccount)
                _ = try! keychain.add(label: "other-holder", service: place.service, account: place.leaseAccount)
                return metadata
            }
            #expect(try await renew(credential, refused: "at-1") == "at-other")
            #expect(
                server.requests(to: "/oauth/token").isEmpty,
                "the spent refresh token was sent: \(server.requests(to: "/oauth/token").map(\.form))")
            #expect(try place.read()?.refreshToken == "rt-other")
        }
    }

    @Test func aRenewalWhoseKeptRefreshTokenChangedWhileReadingTheMetadataSendsNothing() async throws {
        let server = ScriptedAuthServer()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, credential) = try signedInAtEarlierEndpoint(server, keychain)
            let place = authorization.place
            let metadata = server.discovery()
            server.answer { request in
                guard request.path == "/.well-known/oauth-authorization-server" else { return .json(404, [:]) }
                // The lease is still this renewal's, but the kept sign-in was rotated under it.
                var rotated = try! place.read()!
                rotated.accessToken = "at-other"
                rotated.refreshToken = "rt-other"
                try! place.keep(rotated)
                return metadata
            }
            #expect(try await renew(credential, refused: "at-1") == "at-other")
            #expect(server.requests(to: "/oauth/token").isEmpty)
            #expect(try place.read()?.refreshToken == "rt-other")
        }
    }

    @Test(arguments: [400, 403, 404, 410])
    func aClientErrorOnTheMetadataReadItselfFailsTheRenewalAndKeepsTheSignIn(status: Int) async throws {
        let server = ScriptedAuthServer()
        server.answer { request in
            .json(request.path == "/.well-known/oauth-authorization-server" ? status : 404, [:])
        }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, credential) = try signedInAtEarlierEndpoint(server, keychain)
            await #expect {
                try await renew(credential, refused: "at-1")
            } throws: { error in
                guard case RenewalError.Failed = error else { return false }
                return true
            }
            // A proxy's 403 or 404 on the metadata does not show that the grant ended.
            #expect(try authorization.place.read()?.refreshToken == "rt-1")
            #expect(server.requests(to: "/oauth/token").isEmpty)
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
                var transport = server.transport()
                transport.timeLimit = .milliseconds(500)
                transport.requestLimit = .seconds(1)
                let (authorization, credential) = try signedIn(server, keychain, transport: transport)
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

    @Test func aRenewalHoldsTheLeaseForNoLongerThanTheRequestLimitInAllOverItsRequests() async throws {
        let server = ScriptedAuthServer()
        let first = Hold()
        server.answer { request in
            request.path == "/oauth/token" ? .held(first, .json(404, [:])) : .silence
        }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            var transport = server.transport()
            transport.timeLimit = .seconds(5)
            transport.requestLimit = .seconds(2)
            let (authorization, credential) = try signedIn(server, keychain, transport: transport)
            let renewing = Task { try await renew(credential, refused: "at-1") }
            try await eventually("the renewal asks the server") { server.requests(to: "/oauth/token").count == 1 }
            // The token endpoint answers after half the limit, and the metadata read that follows never does.
            try await Task.sleep(for: .seconds(1))
            let released = ContinuousClock.now
            first.release()
            await #expect {
                try await renewing.value
            } throws: { error in
                guard case RenewalError.Unavailable = error else { return false }
                return true
            }
            // The metadata read is cut off at the limit of the whole renewal, a second on, not a limit of its own.
            #expect(ContinuousClock.now - released < .milliseconds(1600))
            try await eventually("the lease is let go") {
                (try? keychain.label(service: service, account: authorization.place.leaseAccount)) == .some(nil)
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

    @Test func aRenewalWhoseRequestOutlivesItsWaitSpendsTheRefreshTokenOnce() async throws {
        let server = ScriptedAuthServer()
        let answer = Hold()
        marfa(server) { _ in .held(answer, tokens("at-2", "rt-2")) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            var transport = server.transport()
            transport.timeLimit = .milliseconds(200)
            let (authorization, holder) = try signedIn(server, keychain, transport: transport)
            let other = try anotherProcess(keychain, server, transport)
            await #expect {
                try await renew(holder, refused: "at-1")
            } throws: { error in
                guard case RenewalError.Unavailable = error else { return false }
                return true
            }
            let renewed = Task { try await renew(other, refused: "at-1") }
            answer.release()
            #expect(try await renewed.value == "at-2")
            #expect(server.requests(to: "/oauth/token").map { $0.form["refresh_token"] } == ["rt-1"])
            #expect(try authorization.place.read()?.refreshToken == "rt-2")
        }
    }

    @Test func aRenewalThatGaveUpKeepsTheAnswerThatArrivesLate() async throws {
        let server = ScriptedAuthServer()
        let answer = Hold()
        marfa(server) { _ in .held(answer, tokens("at-2", "rt-2")) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            var transport = server.transport()
            transport.timeLimit = .milliseconds(200)
            let (authorization, credential) = try signedIn(server, keychain, transport: transport)
            await #expect {
                try await renew(credential, refused: "at-1")
            } throws: { error in
                guard case RenewalError.Unavailable = error else { return false }
                return true
            }
            #expect(try authorization.place.read()?.refreshToken == "rt-1")
            answer.release()
            try await eventually("the late answer is kept", within: 30) {
                (try? authorization.place.read()?.refreshToken) == "rt-2"
            }
            #expect(try authorization.place.read()?.accessToken == "at-2")
            try await eventually("the lease is let go", within: 30) {
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
            for (reply, issuesTokens) in [(tokens("at-2", "rt-2"), true), (oauthError("invalid_grant"), false)] {
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
                    // Only a 200 answer for a sign-in that is gone leaves a grant nothing holds, so only it is revoked.
                    let revoked = server.requests(to: "/oauth/revoke").map(\.form)
                    if change == "signed out", issuesTokens {
                        #expect(
                            revoked == [["token": "rt-2", "token_type_hint": "refresh_token", "client_id": "client-1"]])
                    } else {
                        #expect(revoked.isEmpty, "\(change)")
                    }
                }
            }
        }
    }

    /// A sign-in whose lease is reached through `fault`, renewed by the credential it answers.
    private func faultyRenewal(
        _ server: ScriptedAuthServer, _ keychain: Keychain, _ transport: SignInTransport, _ fault: KeychainFault
    ) throws -> (SignInPlace, Credential) {
        let (authorization, _) = try signedIn(server, keychain, transport: transport)
        let place = authorization.place
        let faulty = try Authorization(
            server: server.url, client: client, keychain: fault.on(keychain, account: place.leaseAccount),
            service: service, transport: transport)
        return (place, try #require(try faulty.credential()))
    }

    @Test func aKeychainErrorWhileTheLeaseIsMovedOnKeepsTheRenewedSignIn() async throws {
        let server = ScriptedAuthServer()
        let fault = KeychainFault()
        let answer = Hold()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            var transport = server.transport()
            transport.leaseLifetime = .milliseconds(300)
            let (place, credential) = try faultyRenewal(server, keychain, transport, fault)
            // While the request is out, only the heartbeat moves the lease, and its next move fails once.
            marfa(server) { _ in
                fault.fail(1)
                return .held(answer, tokens("at-2", "rt-2"))
            }
            let renewed = Task { try await renew(credential, refused: "at-1") }
            try await eventually("a heartbeat meets the keychain error", within: 30) { fault.failed == 1 }
            answer.release()
            #expect(try await renewed.value == "at-2")
            #expect(try place.read()?.refreshToken == "rt-2")
        }
    }

    @Test func aKeychainErrorAsTheRenewalWritesIsTriedAgainAndTheRenewedSignInKept() async throws {
        let server = ScriptedAuthServer()
        let fault = KeychainFault()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            // No heartbeat falls due before the answer: the renewal's own move of the lapse meets the error.
            let (place, credential) = try faultyRenewal(server, keychain, server.transport(), fault)
            marfa(server) { _ in
                fault.fail(1)
                return tokens("at-2", "rt-2")
            }
            #expect(try await renew(credential, refused: "at-1") == "at-2")
            #expect(fault.failed == 1)
            #expect(try place.read()?.refreshToken == "rt-2")
        }
    }

    @Test func aRenewalAnsweredAfterItsHeartbeatsFailedKeepsTheRenewedSignIn() async throws {
        let server = ScriptedAuthServer()
        let fault = KeychainFault()
        let answer = Hold()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let leases = LeaseClock()
            var transport = server.transport(leases: leases)
            transport.leaseLifetime = .milliseconds(300)
            let (place, credential) = try faultyRenewal(server, keychain, transport, fault)
            marfa(server) { _ in
                fault.fail()
                return .held(answer, tokens("at-2", "rt-2"))
            }
            // Every move of the lapse while the request is out fails, until the lease has lapsed; the server has
            // spent rt-1 by the time it answers.
            let renewed = Task { try await renew(credential, refused: "at-1") }
            try await eventually("two heartbeats meet keychain errors", within: 30) { fault.failed >= 2 }
            leases.advance(transport.leaseLifetime * 2)
            let label = try #require(try keychain.label(service: service, account: place.leaseAccount))
            #expect(RenewalLease.lapsed(label, lifetime: transport.leaseLifetime, now: leases.now))
            fault.stop()
            answer.release()
            #expect(try await renewed.value == "at-2")
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
        let leases = LeaseClock()
        let transport = ScriptedAuthServer().transport(leases: leases)
        let account = "https://lease.example"
        let place = SignInPlace(
            keychain: fault.on(keychain, account: "\(account) renewing"), service: service, account: account)
        let lease = try await background { try RenewalLease.take(place, transport) }
        defer { lease.release() }
        #expect(try lease.whileHeld { true } == true)
        fault.fail()
        leases.advance(transport.leaseLifetime + .milliseconds(300))
        let label = try #require(try keychain.label(service: service, account: place.leaseAccount))
        #expect(RenewalLease.lapsed(label, lifetime: transport.leaseLifetime, now: leases.now))
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
                #expect(!RenewalLease.lapsed(label, lifetime: transport.leaseLifetime, now: transport.leaseClock()))
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
            #expect(server.requests(to: "/oauth/token").isEmpty)
        }
    }

    @Test func aHeldLeaseIsMovedOnByItsHeartbeatSoNoOneTakesIt() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let leases = LeaseClock()
            let transport = ScriptedAuthServer().transport(leases: leases).with(leaseLifetime: .milliseconds(600))
            let place = SignInPlace(keychain: keychain, service: service, account: "https://lease.example")
            let held = try await background { try RenewalLease.take(place, transport) }
            defer { held.release() }
            let first = try #require(try keychain.label(service: service, account: place.leaseAccount))
            leases.advance(transport.leaseLifetime * 2)
            #expect(RenewalLease.lapsed(first, lifetime: transport.leaseLifetime, now: leases.now))
            try await eventually("the heartbeat moves the lapse on", within: 30) {
                guard let label = try keychain.label(service: service, account: place.leaseAccount) else {
                    return false
                }
                return !RenewalLease.lapsed(label, lifetime: transport.leaseLifetime, now: leases.now)
            }
            let other = SignInPlace(
                keychain: Keychain(narrow: keychain.narrow), service: place.service, account: place.account)
            await #expect(throws: RenewalLease.Held.self) {
                try await background { try RenewalLease.take(other, transport) }
            }
            #expect(try held.whileHeld { true } == true)
        }
    }

    @Test func aLeaseAnotherProcessHoldsIsWaitedOnAndALapsedOneTaken() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in tokens("at-2", "rt-2") }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let leases = LeaseClock()
            let transport = server.transport(leases: leases).with(leaseLifetime: .seconds(1))
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
            #expect(server.requests(to: "/oauth/token").isEmpty)
            #expect(try held.whileHeld { true } == true)
            held.release()

            // Lapsed on the shared clock; written before a restart, whose clock has started again; further ahead
            // than any lease lasts, as one written before a restart whose boot could not be told apart; unreadable.
            for left in [
                "dead \(boot) \(leases.now - 1_000_000_000)",
                "before-restart 00000000-0000-0000-0000-000000000000 \(leases.now + 600_000_000_000)",
                "too-far-ahead \(boot) \(leases.now + 600_000_000_000)",
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

    @Test func aLeaseLabelNamesThisBootAndALapseOnTheSharedClock() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let transport = SignInTransport.standard
            let place = SignInPlace(keychain: keychain, service: service, account: "https://lease.example")
            // The clock the lease's heartbeat runs on, which stops while the device sleeps, as the heartbeat does.
            let before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let lease = try await background { try RenewalLease.take(place, transport) }
            defer { lease.release() }
            let after = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let label = try #require(try keychain.label(service: service, account: place.leaseAccount))
            let parts = label.split(separator: " ").map(String.init)
            #expect(parts.count == 3)
            #expect(UUID(uuidString: parts[1]) != nil)
            let lapses = try #require(UInt64(parts[2]))
            #expect(lapses >= before + 60_000_000_000 && lapses <= after + 60_000_000_000)
            #expect(!RenewalLease.lapsed(label, lifetime: .seconds(60), now: after))
            #expect(RenewalLease.lapsed(label, lifetime: .seconds(60), now: lapses))
        }
    }
}

/// A Marfa server whose registrations answer `client-2`, `client-3` and so on, whose token answers are `at-2`
/// and `rt-2`, then `at-3` and `rt-3`, and whose revocations `revocation` answers.
///
/// With `forgetting`, it is a server replaced at the same address: it knows only the clients registered with it
/// since, and refuses any other client as the real one does.
private func replacingServer(
    forgetting: Bool = false,
    revocation: @escaping @Sendable (ScriptedAuthServer.Request) -> ScriptedAuthServer.Reply = { _ in .json(200, [:]) }
) -> ScriptedAuthServer {
    let server = ScriptedAuthServer()
    let origin = server.origin
    let discovery = server.discovery()
    let issued = Mutex((clients: 1, tokens: 1))
    server.answer { request in
        let asking = ["/oauth/token", "/oauth/device-authorization", "/oauth/revoke"].contains(request.path)
        if forgetting, asking, !serverKnows(request.form["client_id"] ?? "", issued: issued.withLock { $0.clients }) {
            return oauthError("invalid_client", status: request.path == "/oauth/device-authorization" ? 400 : 401)
        }
        switch request.path {
        case "/.well-known/oauth-authorization-server": return discovery
        case "/oauth/register", "/oauth/token":
            let registering = request.path == "/oauth/register"
            let count = issued.withLock { issued in
                if registering { issued.clients += 1 } else { issued.tokens += 1 }
                return registering ? issued.clients : issued.tokens
            }
            return registering ? .json(201, ["client_id": "client-\(count)"]) : tokens("at-\(count)", "rt-\(count)")
        case "/oauth/device-authorization":
            return .json(
                200,
                [
                    "device_code": "device-1", "user_code": "ABCD-EFGH", "verification_uri": "\(origin)/auth/device",
                    "expires_in": 600, "interval": 5,
                ])
        case "/oauth/revoke": return revocation(request)
        default: return .json(404, [:])
        }
    }
    return server
}

/// Whether a server replaced at the same address knows `clientId`, once it has registered `issued` clients.
private func serverKnows(_ clientId: String, issued: Int) -> Bool {
    guard clientId.hasPrefix("client-"), let number = Int(clientId.dropFirst("client-".count)) else { return false }
    return number >= 2 && number <= issued
}

/// Approves a browser sign-in as a replaced server's authorize page does: a client it does not know leaves the
/// person on the server's own error page, which they close.
private func approveWhereKnown(_ server: ScriptedAuthServer) -> @MainActor @Sendable (URL, String) async throws -> URL {
    { url, scheme in
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "client_id" }?
            .value
        guard serverKnows(id ?? "", issued: 1 + server.requests(to: "/oauth/register").count) else {
            throw SignInError.canceled
        }
        return try await approveAtOnce(url, scheme)
    }
}

/// Approves a browser sign-in at once, answering its state.
private let approveAtOnce: @MainActor @Sendable (URL, String) async throws -> URL = { url, _ in
    let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
    return URL(string: "so.marfa.tests:/signed-in?code=the-code&state=\(state ?? "")")!
}

private let deviceClient = Authorization.Client(name: "Device", scopes: ["core.note:read"])

@Suite(.timeLimit(.minutes(1)))
struct SigningInAgain {
    @Test func endsTheGrantOfTheSignInItReplacesOnAnotherClientOnceTheNewOneIsKept() async throws {
        let place = Mutex<SignInPlace?>(nil)
        let keptWhenRevoked = Mutex<[String?]>([])
        let server = replacingServer { _ in
            let held = place.withLock { $0 }.flatMap { try? $0.read() }
            keptWhenRevoked.withLock { $0.append(held?.refreshToken) }
            return .json(200, [:])
        }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, _) = try signedIn(server, keychain, transport: server.transport())
            place.withLock { $0 = authorization.place }
            let credential = try await authorization.startDeviceSignIn().credential()

            #expect(!credential.replacedGrantStands)
            #expect(try authorization.place.read()?.clientId == "client-2")
            let revoked = server.requests(to: "/oauth/revoke").map(\.form)
            #expect(revoked == [["token": "rt-1", "token_type_hint": "refresh_token", "client_id": "client-1"]])
            #expect(keptWhenRevoked.withLock { $0 } == ["rt-2"])
        }
    }

    @Test func aConfirmationRevokesOnlyTheReplacedAccessTokenSinceBothShareAClientAndSoAGrant() async throws {
        let server = replacingServer()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, _) = try signedIn(server, keychain, transport: server.transport())
            let credential = try await authorization.signIn(maxAge: 0, browser: approveAtOnce)

            #expect(!credential.replacedGrantStands)
            #expect(server.requests(to: "/oauth/register").isEmpty)
            #expect(try authorization.place.read()?.refreshToken == "rt-2")
            let revoked = server.requests(to: "/oauth/revoke").map(\.form)
            #expect(revoked == [["token": "at-1", "token_type_hint": "access_token", "client_id": "client-1"]])
        }
    }

    @Test(arguments: [ScriptedAuthServer.Reply.failure(.notConnectedToInternet), .json(503, [:])])
    func aReplacedGrantTheServerDoesNotEndIsReportedAndTheNewSignInKept(answer: ScriptedAuthServer.Reply) async throws {
        let server = replacingServer { _ in answer }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, _) = try signedIn(server, keychain, transport: server.transport())
            let credential = try await authorization.startDeviceSignIn().credential()

            #expect(credential.replacedGrantStands)
            #expect(try authorization.place.read()?.refreshToken == "rt-2")
            #expect(try authorization.credential()?.replacedGrantStands == false)
            #expect(server.requests(to: "/oauth/revoke").map { $0.form["token"] } == ["rt-1"])
        }
    }

    @Test func aFirstSignInEndsNothing() async throws {
        let server = replacingServer()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: deviceClient, keychain: keychain, service: service,
                transport: server.transport())
            let credential = try await authorization.startDeviceSignIn().credential()

            #expect(!credential.replacedGrantStands)
            #expect(server.requests(to: "/oauth/revoke").isEmpty)
        }
    }

    @Test func aSignInToAnotherServerLeavesThisServersSignInAlone() async throws {
        let first = ScriptedAuthServer()
        marfa(first) { _ in .json(200, [:]) }
        let other = replacingServer()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (kept, _) = try signedIn(first, keychain, transport: first.transport())
            let authorization = try Authorization(
                server: other.url, client: deviceClient, keychain: keychain, service: service,
                transport: other.transport())
            _ = try await authorization.startDeviceSignIn().credential()

            #expect(first.requests.isEmpty)
            #expect(other.requests(to: "/oauth/revoke").isEmpty)
            #expect(try kept.place.read()?.refreshToken == "rt-1")
        }
    }

    @Test func theReplacedSignInIsTheOneKeptWhenTheNewOneIsKept() async throws {
        let server = replacingServer()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, _) = try signedIn(server, keychain, transport: server.transport())
            let started = try await authorization.startDeviceSignIn()
            // Another process sharing the keychain signs in while this one waits for its approval.
            var meanwhile = try #require(try authorization.place.read())
            meanwhile.clientId = "client-9"
            meanwhile.refreshToken = "rt-9"
            try authorization.place.keep(meanwhile)
            _ = try await started.credential()

            let revoked = server.requests(to: "/oauth/revoke").map(\.form)
            #expect(revoked == [["token": "rt-9", "token_type_hint": "refresh_token", "client_id": "client-9"]])
        }
    }

    @Test func aConfirmationThatCannotBeKeptOnTheKeptSignInsClientRevokesOnlyItsAccessToken() async throws {
        let server = replacingServer()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            var transport = server.transport()
            transport.leaseLifetime = .seconds(1)
            let (authorization, _) = try signedIn(server, keychain, transport: transport)
            let held = try await heldElsewhere(authorization.place, transport)
            defer { held.release() }
            await #expect(throws: SignInError.heldElsewhere) {
                try await authorization.signIn(maxAge: 0, browser: approveAtOnce)
            }

            #expect(try authorization.place.read()?.refreshToken == "rt-1")
            let revoked = server.requests(to: "/oauth/revoke").map(\.form)
            #expect(revoked == [["token": "at-2", "token_type_hint": "access_token", "client_id": "client-1"]])
        }
    }

    @Test func anApprovalOnANewClientThatAnUnreadableKeychainCannotKeepIsRevokedByItsRefreshToken() async throws {
        let server = replacingServer()
        let fault = KeychainFault()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (kept, _) = try signedIn(server, keychain, transport: server.transport())
            let authorization = try Authorization(
                server: server.url, client: deviceClient, keychain: fault.on(keychain, account: kept.place.account),
                service: service, transport: server.transport())
            let started = try await authorization.startDeviceSignIn()
            fault.fail()
            await #expect(throws: Keychain.Failure.self) { try await started.credential() }
            fault.stop()

            #expect(try kept.place.read()?.refreshToken == "rt-1")
            let revoked = server.requests(to: "/oauth/revoke").map(\.form)
            #expect(revoked == [["token": "rt-2", "token_type_hint": "refresh_token", "client_id": "client-2"]])
        }
    }

    @Test func aConfirmationOnTheKeptClientThatAnUnreadableKeychainCannotKeepRevokesOnlyItsAccessToken() async throws {
        let server = replacingServer()
        let fault = KeychainFault()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (kept, _) = try signedIn(server, keychain, transport: server.transport())
            let authorization = try Authorization(
                server: server.url, client: client, keychain: fault.on(keychain, account: kept.place.account),
                service: service, transport: server.transport())
            await #expect(throws: Keychain.Failure.self) {
                try await authorization.signIn(maxAge: 0) { url, scheme in
                    fault.fail()
                    return try await approveAtOnce(url, scheme)
                }
            }
            fault.stop()

            #expect(server.requests(to: "/oauth/register").isEmpty)
            #expect(try kept.place.read()?.refreshToken == "rt-1")
            let revoked = server.requests(to: "/oauth/revoke").map(\.form)
            #expect(revoked == [["token": "at-2", "token_type_hint": "access_token", "client_id": "client-1"]])
        }
    }

    @Test func aBrowserSignInToAReplacedServerRegistersANewClientAndCompletes() async throws {
        let server = replacingServer(forgetting: true)
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            // The kept sign-in names a client the server at this address has never heard of.
            let (authorization, _) = try signedIn(server, keychain, transport: server.transport())
            let credential = try await authorization.signIn(browser: approveWhereKnown(server))

            #expect(server.requests(to: "/oauth/register").count == 1)
            let kept = try #require(try authorization.place.read())
            #expect(kept.clientId == "client-2")
            #expect(try authorization.credential() == credential)
            #expect(try #require(server.requests(to: "/oauth/token").first).form["client_id"] == "client-2")
            // The replaced server holds no grant for the old client, which it says by refusing it.
            #expect(!credential.replacedGrantStands)
            let revoked = server.requests(to: "/oauth/revoke").map(\.form)
            #expect(revoked == [["token": "rt-1", "token_type_hint": "refresh_token", "client_id": "client-1"]])
        }
    }

    @Test func aDeviceSignInToAReplacedServerRegistersANewClientAndCompletes() async throws {
        let server = replacingServer(forgetting: true)
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, _) = try signedIn(server, keychain, transport: server.transport())
            // The kept sign-in is a device one, on a client the server forgot.
            var kept = try #require(try authorization.place.read())
            kept.grantTypes = [deviceCodeGrant, "refresh_token"]
            kept.redirect = nil
            try authorization.place.keep(kept)
            let credential = try await authorization.startDeviceSignIn().credential()

            #expect(server.requests(to: "/oauth/register").count == 1)
            #expect(try authorization.place.read()?.clientId == "client-2")
            #expect(!credential.replacedGrantStands)
        }
    }

    @Test func aCancelAfterTheCodeExchangeAndBeforeTheWriteChangesNothingKeptAndEndsTheNewGrant() async throws {
        let server = replacingServer()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let transport = server.transport()
            let (authorization, _) = try signedIn(server, keychain, transport: transport)
            let before = try authorization.place.read()
            // The write waits for the lease, so the tokens are in hand and the write is still to come.
            let held = try await heldElsewhere(authorization.place, transport)
            defer { held.release() }
            let signingIn = Task { try await authorization.signIn(browser: approveAtOnce) }
            try await eventually("the code is exchanged") { server.requests(to: "/oauth/token").count == 1 }
            signingIn.cancel()
            held.release()
            await #expect(throws: CancellationError.self) { try await signingIn.value }

            #expect(try authorization.place.read() == before)
            let revoked = server.requests(to: "/oauth/revoke").map(\.form)
            #expect(revoked == [["token": "rt-2", "token_type_hint": "refresh_token", "client_id": "client-2"]])
        }
    }

    @Test func aCanceledSignInChangesNothingAndEndsNothing() async throws {
        let server = replacingServer()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, _) = try signedIn(server, keychain, transport: server.transport())
            let before = try authorization.place.read()
            await #expect(throws: SignInError.canceled) {
                try await authorization.signIn { _, _ in throw SignInError.canceled }
            }
            #expect(try authorization.place.read() == before)
            #expect(server.requests(to: "/oauth/revoke").isEmpty)
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SigningOut {
    @Test func aSignInWithNoRefreshTokenRevokesItsAccessTokenAndSaysTheGrantStands() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in .json(200, [:]) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, _) = try signedIn(server, keychain, transport: server.transport(), refresh: nil)
            #expect(try await authorization.signOut() == .notConfirmed)
            let revoked = try #require(server.requests(to: "/oauth/revoke").first).form
            #expect(revoked == ["token": "at-1", "token_type_hint": "access_token", "client_id": "client-1"])
        }
    }

    @Test func deletesTheSignInThenRevokesTheRefreshToken() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in .json(200, [:]) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, _) = try signedIn(server, keychain, transport: server.transport())
            #expect(try await authorization.signOut() == .endedAtServer)
            #expect(try authorization.place.read() == nil)
            let revoked = try #require(server.requests(to: "/oauth/revoke").first).form
            #expect(revoked == ["token": "rt-1", "token_type_hint": "refresh_token", "client_id": "client-1"])
        }
    }

    @Test func aSignOutThatCannotTakeTheLeaseSaysSoAndChangesNothing() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in .json(200, [:]) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            var transport = server.transport()
            transport.leaseLifetime = .seconds(1)
            let (authorization, _) = try signedIn(server, keychain, transport: transport)
            let held = try await heldElsewhere(authorization.place, transport)
            defer { held.release() }
            await #expect(throws: SignInError.heldElsewhere) { try await authorization.signOut() }
            #expect(try authorization.place.read()?.refreshToken == "rt-1")
            #expect(server.requests(to: "/oauth/revoke").isEmpty)
        }
    }

    @Test func aRevocationTheServerDoesNotConfirmStillSignsOutHere() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in .failure(.notConnectedToInternet) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, _) = try signedIn(server, keychain, transport: server.transport())
            #expect(try await authorization.signOut() == .notConfirmed)
            #expect(try authorization.place.read() == nil)
            #expect(try await authorization.signOut() == .nothingKept)
        }
    }

    @Test func aSignInTheRenewerDroppedLeavesNothingToEnd() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { request in
            request.path == "/oauth/token" ? oauthError("invalid_grant") : .json(200, [:])
        }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, credential) = try signedIn(server, keychain, transport: server.transport())
            await #expect(throws: RenewalError.self) { try await renew(credential, refused: "at-1") }
            #expect(try authorization.place.read() == nil)
            #expect(try await authorization.signOut() == .nothingKept)
            #expect(server.requests(to: "/oauth/revoke").isEmpty)
        }
    }

    /// Keeps a sign-in whose revocation endpoint is one the server no longer serves.
    private func signedInAtEarlierEndpoint(
        _ server: ScriptedAuthServer, _ keychain: Keychain
    ) throws -> Authorization {
        let (authorization, _) = try signedIn(server, keychain, transport: server.transport())
        var kept = try #require(try authorization.place.read())
        kept.revocationEndpoint = "\(server.origin)/auth/oauth2/revoke"
        try authorization.place.keep(kept)
        return authorization
    }

    @Test(arguments: [404, 410])
    func aRevocationEndpointTheServerNoLongerHasIsReadAgainAndRevokedOnceWhereItIsNow(status: Int) async throws {
        let server = ScriptedAuthServer()
        marfa(server) { request in request.path == "/oauth/revoke" ? .json(200, [:]) : .json(status, [:]) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try signedInAtEarlierEndpoint(server, keychain)
            #expect(try await authorization.signOut() == .endedAtServer)
            let asked = ["/auth/oauth2/revoke", "/.well-known/oauth-authorization-server", "/oauth/revoke"]
            #expect(server.requests.map(\.path) == asked)
            let sent = try #require(server.requests(to: "/oauth/revoke").first).form
            #expect(sent == ["token": "rt-1", "token_type_hint": "refresh_token", "client_id": "client-1"])
            #expect(try authorization.place.read() == nil)
        }
    }

    @Test func aRevocationEndpointStillGoneWhereTheMetadataNowPointsIsNotConfirmedAfterOneMoreTry() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in .json(404, [:]) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try signedInAtEarlierEndpoint(server, keychain)
            #expect(try await authorization.signOut() == .notConfirmed)
            #expect(server.requests(to: "/auth/oauth2/revoke").count == 1)
            #expect(server.requests(to: "/oauth/revoke").count == 1)
            #expect(try authorization.place.read() == nil)
        }
    }

    @Test func aGoneEndpointTheMetadataStillNamesIsNotAskedAgain() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in .json(404, [:]) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, _) = try signedIn(server, keychain, transport: server.transport())
            #expect(try await authorization.signOut() == .notConfirmed)
            #expect(server.requests.map(\.path) == ["/oauth/revoke", "/.well-known/oauth-authorization-server"])
        }
    }

    @Test(arguments: [
        ScriptedAuthServer.Reply.json(404, [:]), .json(503, [:]), .failure(.notConnectedToInternet),
        .json(200, ["issuer": "https://elsewhere.example"]),
    ])
    func aGoneEndpointWhoseMetadataCannotBeReadIsNotConfirmed(metadata: ScriptedAuthServer.Reply) async throws {
        let server = ScriptedAuthServer()
        server.answer { request in
            request.path == "/.well-known/oauth-authorization-server" ? metadata : .json(404, [:])
        }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try signedInAtEarlierEndpoint(server, keychain)
            #expect(try await authorization.signOut() == .notConfirmed)
            #expect(server.requests.map(\.path) == ["/auth/oauth2/revoke", "/.well-known/oauth-authorization-server"])
            #expect(try authorization.place.read() == nil)
        }
    }

    @Test func aRefusalThatIsAnOAuthErrorIsNeverTakenForAMissingRevocationEndpoint() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in oauthError("invalid_request", status: 404) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, _) = try signedIn(server, keychain, transport: server.transport())
            #expect(try await authorization.signOut() == .notConfirmed)
            #expect(server.requests.map(\.path) == ["/oauth/revoke"])
        }
    }

    @Test(arguments: [400, 401])
    func aRevocationRefusedForAClientTheServerDoesNotKnowCountsAsEnded(status: Int) async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in oauthError("invalid_client", status: status) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, _) = try signedIn(server, keychain, transport: server.transport())
            #expect(try await authorization.signOut() == .endedAtServer)
            #expect(try authorization.place.read() == nil)
        }
    }

    @Test(arguments: [
        ScriptedAuthServer.Reply.json(503, [:]), .json(500, [:]), .failure(.notConnectedToInternet),
        oauthError("invalid_request"), .json(401, [:]),
    ])
    func aRevocationTheServerDoesNotConfirmIsNotConfirmedAndTheSignInIsGoneHere(
        answer: ScriptedAuthServer.Reply
    ) async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in answer }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, _) = try signedIn(server, keychain, transport: server.transport())
            #expect(try await authorization.signOut() == .notConfirmed)
            #expect(try authorization.place.read() == nil)
        }
    }

    @Test func aSignOutBesideARenewalThatRotatesTheTokenWaitsForItAndEndsTheGrantItRenewed() async throws {
        let server = ScriptedAuthServer()
        let answer = Hold()
        // The server ends a grant only when it is asked to revoke the refresh token it holds now: a rotated
        // refresh token is ignored and still answered 200, as marfa-server does.
        let current = Mutex("rt-1")
        let ended = Mutex(false)
        marfa(server) { request in
            switch request.path {
            case "/oauth/token":
                current.withLock { $0 = "rt-2" }
                return .held(answer, tokens("at-2", "rt-2"))
            case "/oauth/revoke":
                if request.form["token"] == current.withLock({ $0 }) { ended.withLock { $0 = true } }
                return .json(200, [:])
            default: return .json(404, [:])
            }
        }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, credential) = try signedIn(server, keychain, transport: server.transport())
            let renewing = Task { try await renew(credential, refused: "at-1") }
            try await eventually("the renewal asks the server") { server.requests(to: "/oauth/token").count == 1 }

            let signingOut = Task { try await authorization.signOut() }
            // The sign-out waits for the renewal, which holds the lease, so it has revoked nothing yet.
            try await Task.sleep(for: .milliseconds(300))
            #expect(server.requests(to: "/oauth/revoke").isEmpty)
            answer.release()

            #expect(try await renewing.value == "at-2")
            #expect(try await signingOut.value == .endedAtServer)
            let revoked = try #require(server.requests(to: "/oauth/revoke").first).form
            #expect(revoked == ["token": "rt-2", "token_type_hint": "refresh_token", "client_id": "client-1"])
            #expect(ended.withLock { $0 }, "the outcome says ended, so the grant really ended")
            #expect(try authorization.place.read() == nil)
        }
    }

    @Test func aSignOutWhileAnotherProcessHoldsTheLeaseDeletesNothingBesideARenewalWaitingForIt() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in .json(200, [:]) }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            var transport = server.transport()
            transport.leaseLifetime = .seconds(1)
            let (authorization, credential) = try signedIn(server, keychain, transport: transport)
            let held = try await heldElsewhere(authorization.place, transport)
            defer { held.release() }
            // A renewal in this process holds the gate, waiting for the lease the other process holds.
            let renewing = Task { try await renew(credential, refused: "at-1") }
            try await Task.sleep(for: .milliseconds(200))
            await #expect(throws: SignInError.heldElsewhere) { try await authorization.signOut() }
            _ = try? await renewing.value
            #expect(try authorization.place.read()?.refreshToken == "rt-1")
            #expect(server.requests(to: "/oauth/revoke").isEmpty)
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

    @Test(arguments: [
        "https://owner@marfa.example.com", "https://owner:hunter2@marfa.example.com/",
        "https://a%40b:c%3Ad@marfa.example.com",
    ])
    func anAddressWithUserInfoIsRefused(address: String) throws {
        let url = try #require(URL(string: address))
        #expect(throws: SignInError.notAServer) {
            try Authorization(server: url, client: client, keychain: Keychain(), service: service)
        }
    }

    @Test func aCredentialIsRefusedForAnAddressWithUserInfo() async throws {
        let server = ScriptedAuthServer()
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (_, credential) = try signedIn(server, keychain, transport: server.transport())
            var parts = try #require(URLComponents(url: server.url, resolvingAgainstBaseURL: false))
            parts.user = "owner"
            parts.password = "hunter2"
            let withUser = try #require(parts.url)
            #expect(throws: SignInError.notAServer) { try Server(url: withUser, credential: credential) }
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

@Suite(.timeLimit(.minutes(1)))
struct SignInContractHeader {
    private let contract = String(marfaContractVersion)

    @Test func everyRequestOfABrowserSignInNamesTheContract() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { request in
            request.path == "/oauth/token" ? tokens("at-1", "rt-1") : .json(404, [:])
        }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: client, keychain: keychain, service: service,
                transport: server.transport())
            _ = try await authorization.signIn { url, _ in
                let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "state" }?.value
                return URL(string: "so.marfa.tests:/signed-in?code=the-code&state=\(state ?? "")")!
            }
        }
        let paths = Set(server.requests.map(\.path))
        #expect(
            paths == ["/.well-known/oauth-authorization-server", "/oauth/register", "/oauth/token"], "\(paths)")
        for request in server.requests {
            #expect(request.headers["X-Marfa-Contract"] == contract, "\(request.path)")
        }
    }

    @Test func everyRequestOfADeviceSignInNamesTheContract() async throws {
        let server = ScriptedAuthServer()
        let origin = server.origin
        marfa(server) { request in
            switch request.path {
            case "/oauth/device-authorization":
                .json(
                    200,
                    [
                        "device_code": "device-1", "user_code": "ABCD-EFGH",
                        "verification_uri": "\(origin)/auth/device", "expires_in": 600, "interval": 5,
                    ])
            case "/oauth/token": tokens("at-1", "rt-1")
            default: .json(404, [:])
            }
        }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: server.url, client: Authorization.Client(name: "Device", scopes: ["core.note:read"]),
                keychain: keychain, service: service, transport: server.transport())
            _ = try await authorization.startDeviceSignIn().credential()
        }
        #expect(server.requests(to: "/oauth/device-authorization").count == 1)
        #expect(server.requests(to: "/oauth/token").count == 1)
        for request in server.requests {
            #expect(request.headers["X-Marfa-Contract"] == contract, "\(request.path)")
        }
    }

    @Test func aTokenRenewalNamesTheContract() async throws {
        let server = ScriptedAuthServer()
        marfa(server) { _ in tokens("at-2", "rt-2") }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (_, credential) = try signedIn(server, keychain, transport: server.transport())
            #expect(try await renew(credential, refused: "at-1") == "at-2")
        }
        let renewal = try #require(server.requests(to: "/oauth/token").first)
        #expect(renewal.headers["X-Marfa-Contract"] == contract)
    }
}

/// Two loopback servers on a plain session: `first` is the server a sign-in is addressed to, and answers
/// `status` with a `Location` on `second` for each path in `redirected`. `second` answers 200 to anything.
private struct Origins {
    let first: LocalServer
    let second: LocalServer
    let transport = SignInTransport(session: URLSession(configuration: .ephemeral))

    /// `body` is what the redirect carries, which the package never reads for an error code.
    static func start(
        status: Int, redirected: Set<String>, body: String = "{}",
        rest: @escaping @Sendable (_ path: String, _ origin: String) -> LocalServer.Answer = { _, _ in
            (404, "application/json", "{}")
        }
    ) async throws -> Origins {
        let second = try await LocalServer.start(contract: marfaContractVersion) { _, _ in
            (200, "application/json", "{}")
        }
        let origin = Mutex("")
        let first = try await LocalServer.start(
            contract: marfaContractVersion,
            redirects: Dictionary(
                uniqueKeysWithValues: redirected.compactMap { path in
                    URL(string: "\(second.url.absoluteString)/landing").map { (path, $0) }
                })
        ) { _, path in
            if redirected.contains(path) { return (status, "application/json", body) }
            return rest(path, origin.withLock { $0 })
        }
        origin.withLock { $0 = first.url.absoluteString }
        return Origins(first: first, second: second)
    }

    func stop() {
        first.stop()
        second.stop()
    }

    static func metadata(_ origin: String) -> LocalServer.Answer {
        let body = """
            {"issuer":"\(origin)","authorization_endpoint":"\(origin)/oauth/authorize",\
            "token_endpoint":"\(origin)/oauth/token","device_authorization_endpoint":"\(origin)/oauth/device-authorization",\
            "registration_endpoint":"\(origin)/oauth/register","revocation_endpoint":"\(origin)/oauth/revoke"}
            """
        return (200, "application/json", body)
    }

    static func marfa(
        _ rest: @escaping @Sendable (_ path: String) -> LocalServer.Answer = { _ in (404, "application/json", "{}") }
    ) -> @Sendable (_ path: String, _ origin: String) -> LocalServer.Answer {
        { path, origin in
            switch path {
            case "/.well-known/oauth-authorization-server": metadata(origin)
            case "/oauth/register": (201, "application/json", #"{"client_id":"client-1"}"#)
            default: rest(path)
            }
        }
    }

    /// Nothing reached `second`, and `second` is reachable the same way: a request sent straight to it arrives.
    func expectUntouched() async throws {
        #expect(second.log.all.isEmpty)
        let request = try formRequest("\(second.url.absoluteString)/oauth/token", [("grant_type", "refresh_token")])
        let answer = try await send(request, transport)
        #expect(answer.status == 200)
        #expect(second.log.all.count == 1)
        #expect(second.log.all.first?.hasPrefix("POST /oauth/token") == true)
    }

    func signedIn(_ keychain: Keychain, endpoint: String) throws -> (Authorization, Credential) {
        let authorization = try Authorization(
            server: first.url, client: client, keychain: keychain, service: service, transport: transport)
        try authorization.place.keep(
            KeptSignIn(
                clientId: "client-1", grantTypes: ["authorization_code", "refresh_token"],
                redirect: client.redirect?.absoluteString, accessToken: "at-1", refreshToken: "rt-1",
                scope: "core.note:read offline_access", tokenEndpoint: "\(first.url.absoluteString)\(endpoint)",
                revocationEndpoint: "\(first.url.absoluteString)/oauth/revoke"))
        return (authorization, try #require(try authorization.credential()))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SignInRequestsRefuseRedirects {
    @Test(arguments: [307, 302], ["{}", #"{"error":"invalid_grant"}"#, #"{"error":"invalid_client"}"#])
    func aRenewalAnsweredByARedirectFailsAndKeepsTheSignIn(status: Int, body: String) async throws {
        let origins = try await Origins.start(
            status: status, redirected: ["/oauth/token"], body: body, rest: Origins.marfa())
        defer { origins.stop() }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, credential) = try origins.signedIn(keychain, endpoint: "/oauth/token")
            await #expect {
                try await renew(credential, refused: "at-1")
            } throws: { error in
                guard case RenewalError.Failed = error else { return false }
                return true
            }
            #expect(try authorization.place.read()?.refreshToken == "rt-1")
            // A redirect is not a token endpoint that has gone, so the metadata is not read and nothing is retried.
            #expect(origins.first.log.all.count == 1)
        }
        try await origins.expectUntouched()
    }

    @Test(arguments: [307, 302])
    func aRenewalWhoseMetadataReadIsAnsweredByARedirectFailsAndKeepsTheSignIn(status: Int) async throws {
        let origins = try await Origins.start(status: status, redirected: ["/.well-known/oauth-authorization-server"])
        defer { origins.stop() }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, credential) = try origins.signedIn(keychain, endpoint: "/auth/oauth2/token")
            await #expect {
                try await renew(credential, refused: "at-1")
            } throws: { error in
                guard case RenewalError.Failed = error else { return false }
                return true
            }
            #expect(try authorization.place.read()?.refreshToken == "rt-1")
            #expect(origins.first.log.all.count == 2)
        }
        try await origins.expectUntouched()
    }

    @Test(arguments: [307, 302])
    func aMetadataReadAnsweredByARedirectIsRefused(status: Int) async throws {
        let origins = try await Origins.start(status: status, redirected: ["/.well-known/oauth-authorization-server"])
        defer { origins.stop() }
        await #expect(throws: SignInError.refused(code: "http_\(status)", message: "the server answered \(status)")) {
            try await Discovery.read(origins.first.url.absoluteString, origins.transport)
        }
        try await origins.expectUntouched()
    }

    @Test(arguments: [307, 302])
    func aDeviceSignInStepAnsweredByARedirectIsRefused(status: Int) async throws {
        let origins = try await Origins.start(
            status: status, redirected: ["/oauth/device-authorization"], rest: Origins.marfa())
        defer { origins.stop() }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: origins.first.url, client: Authorization.Client(name: "Device", scopes: ["core.note:read"]),
                keychain: keychain, service: service, transport: origins.transport)
            await #expect(throws: SignInError.refused(code: "http_\(status)", message: "the server answered \(status)"))
            {
                try await authorization.startDeviceSignIn()
            }
        }
        try await origins.expectUntouched()
    }

    @Test(arguments: [307, 302], ["{}", #"{"error":"authorization_pending"}"#, #"{"error":"slow_down"}"#])
    func aDevicePollAnsweredByARedirectIsRefused(status: Int, body: String) async throws {
        let origin = Mutex("")
        let origins = try await Origins.start(
            status: status, redirected: ["/oauth/token"], body: body,
            rest: Origins.marfa { path in
                guard path == "/oauth/device-authorization" else { return (404, "application/json", "{}") }
                let body = """
                    {"device_code":"device-1","user_code":"ABCD-EFGH",\
                    "verification_uri":"\(origin.withLock { $0 })/auth/device","expires_in":600,"interval":5}
                    """
                return (200, "application/json", body)
            })
        defer { origins.stop() }
        origin.withLock { $0 = origins.first.url.absoluteString }
        var transport = origins.transport
        transport.sleep = { _ in }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let authorization = try Authorization(
                server: origins.first.url, client: Authorization.Client(name: "Device", scopes: ["core.note:read"]),
                keychain: keychain, service: service, transport: transport)
            let started = try await authorization.startDeviceSignIn()
            await #expect(throws: SignInError.refused(code: "http_\(status)", message: "the server answered \(status)"))
            {
                try await started.credential()
            }
            #expect(try authorization.place.read() == nil)
            // Refused at the first poll, not polled again as a pending or slowed grant.
            #expect(origins.first.log.all.filter { $0.hasPrefix("POST /oauth/token ") }.count == 1)
        }
        try await origins.expectUntouched()
    }

    @Test(arguments: [307, 302])
    func aRevocationAnsweredByARedirectIsNotFollowed(status: Int) async throws {
        let origins = try await Origins.start(status: status, redirected: ["/oauth/revoke"])
        defer { origins.stop() }
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let (authorization, _) = try origins.signedIn(keychain, endpoint: "/oauth/token")
            #expect(try await authorization.signOut() == .notConfirmed)
            #expect(try authorization.place.read() == nil)
        }
        try await origins.expectUntouched()
    }
}
