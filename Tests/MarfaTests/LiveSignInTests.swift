import Foundation
import Testing

@testable import Marfa

/// Signs in to a server of its own with the device grant, as an app without a browser does, and follows the
/// sign-in through an access token the server stops accepting, a renewal, and a grant the server ends.
///
/// The server is booted with its test hooks, so the test can move its clock past the access token's lifetime.
@Suite(
    .serialized,
    .enabled(if: OwnServer.monorepo != nil, "set MARFA_MONOREPO to a marfa checkout whose server is built"),
    .timeLimit(.minutes(5)))
struct LiveSignIn {
    static let service = "com.withmarfa.marfa-swift.tests"

    @Test func aDeviceSignInWritesRenewsAndEndsWhenTheGrantIsRevoked() async throws {
        let own = try await OwnServer.boot(testHooks: true)
        do {
            try await inIsolatedKeychainAsync { keychain, _ async throws in
                try await Self.run(own, keychain)
            }
        } catch {
            try await own.end()
            throw error
        }
        try await own.end()
    }

    @Test func signingInAgainLeavesOneGrantAndTheNewSignInWorks() async throws {
        let own = try await OwnServer.boot()
        do {
            try await inIsolatedKeychainAsync { keychain, _ async throws in
                try await Self.signInAgain(own, keychain)
            }
        } catch {
            try await own.end()
            throw error
        }
        try await own.end()
    }

    private static func signInAgain(_ own: OwnServer, _ keychain: Keychain) async throws {
        let authorization = try Authorization(
            server: own.url,
            client: Authorization.Client(
                name: "marfa-swift live tests", redirect: URL(string: "com.withmarfa.marfa-swift.tests:/signed-in"),
                scopes: ["core.note:read"]),
            keychain: keychain, service: service)

        // A device sign-in after a browser one registers another client, and so holds another grant.
        _ = try await authorization.signIn(browser: browserApproval(on: own))
        let browser = try #require(try authorization.place.read())
        #expect(try await grants(own) == [browser.clientId])
        let started = try await authorization.startDeviceSignIn()
        try await approve(started.userCode, on: own)
        #expect(try await started.credential().replacedGrantStands == false)
        let device = try #require(try authorization.place.read())
        #expect(device.clientId != browser.clientId)
        #expect(try await grants(own) == [device.clientId])
        #expect(try await itemsStatus(browser.accessToken, own) == 401)
        #expect(try await itemsStatus(device.accessToken, own) == 200)

        // Another device sign-in reuses the client, so both sign-ins hold one grant, which must stand.
        let again = try await authorization.startDeviceSignIn()
        try await approve(again.userCode, on: own)
        #expect(try await again.credential().replacedGrantStands == false)
        let second = try #require(try authorization.place.read())
        #expect(second.clientId == device.clientId)
        #expect(try await grants(own) == [second.clientId])
        #expect(try await itemsStatus(device.accessToken, own) == 401)
        #expect(try await itemsStatus(second.accessToken, own) == 200)
        let renewal = try formRequest(
            device.tokenEndpoint,
            [
                ("grant_type", "refresh_token"), ("refresh_token", try #require(second.refreshToken)),
                ("client_id", second.clientId),
            ])
        let (_, renewed) = try await URLSession.shared.data(for: renewal)
        #expect((renewed as? HTTPURLResponse)?.statusCode == 200)
    }

    /// The client of every grant the owner approved, as `GET /auth/grants` lists them.
    private static func grants(_ own: OwnServer) async throws -> [String] {
        var request = URLRequest(url: own.url.appending(path: "auth/grants"))
        request.setValue("Bearer \(own.key)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await URLSession.shared.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200, "the grants could not be listed")
        let listed = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return (listed["data"] as? [[String: Any]] ?? []).compactMap { $0["client_id"] as? String }
    }

    /// The status `GET /items` answers an access token, which shows whether it still works.
    private static func itemsStatus(_ accessToken: String, _ own: OwnServer) async throws -> Int {
        var request = URLRequest(
            url: own.url.appending(path: "items").appending(queryItems: [.init(name: "limit", value: "1")]))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// A browser that is the owner's: it approves every scope on the consent screen and answers the address the
    /// server sends it back to.
    private static func browserApproval(on own: OwnServer) -> @MainActor @Sendable (URL, String) async throws -> URL {
        { authorize, scheme in
            let origin = own.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let cookie = try await ownerCookie(own, session)
            var asked = URLRequest(url: authorize)
            asked.setValue(cookie, forHTTPHeaderField: "Cookie")
            var landed = try await sentTo(asked, session, own)
            if landed.scheme != scheme {
                let scopes =
                    URLComponents(url: authorize, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "scope" }?.value?.split(separator: " ").map(String.init) ?? []
                var form = URLComponents()
                form.queryItems =
                    [
                        URLQueryItem(name: "accept", value: "true"),
                        URLQueryItem(name: "oauth_query", value: landed.query()),
                    ]
                    + scopes.map { URLQueryItem(name: "scopes", value: $0) }
                var decision = URLRequest(url: try #require(URL(string: "\(origin)/auth/authorize/decision")))
                decision.httpMethod = "POST"
                decision.setValue(cookie, forHTTPHeaderField: "Cookie")
                decision.setValue(origin, forHTTPHeaderField: "Origin")
                decision.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                decision.httpBody = Data(
                    (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
                landed = try await sentTo(decision, session, own)
            }
            try #require(landed.scheme == scheme, "the approval sent the browser to \(landed)")
            return landed
        }
    }

    /// Where the server sends a browser: a redirect's `Location`, or the `url` it answers a program with.
    private static func sentTo(_ request: URLRequest, _ session: URLSession, _ own: OwnServer) async throws -> URL {
        let (body, response) = try await session.data(for: request, delegate: NoRedirect())
        let http = try #require(response as? HTTPURLResponse)
        let location =
            http.value(forHTTPHeaderField: "Location")
            ?? ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["url"] as? String
        return try #require(location.flatMap { URL(string: $0, relativeTo: own.url)?.absoluteURL })
    }

    private static func run(_ own: OwnServer, _ keychain: Keychain) async throws {
        let authorization = try Authorization(
            server: own.url,
            client: Authorization.Client(
                name: "marfa-swift live tests", scopes: ["core.note:read", "core.note:write"]),
            keychain: keychain, service: service)
        #expect(try authorization.credential() == nil)

        let started = try await authorization.startDeviceSignIn()
        #expect(origin(of: started.verificationURL) == origin(of: own.url))
        try await approve(started.userCode, on: own)
        let credential = try await started.credential()
        #expect(credential.scopes.contains("core.note:write"))
        let signedIn = try #require(try authorization.place.read())
        let firstRefresh = try #require(signedIn.refreshToken)

        let server = try Server(url: own.url, credential: credential)
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: server)
        _ = try await copy.hydrate(types: ["core.note"], tier: .library)
        let before = try await copy.items.create(note("written while the first access token holds"))
        #expect(try await copy.queue.drain().verdicts.map(\.verdict) == [.accepted])
        #expect(try await authorization.place.read()?.accessToken == signedIn.accessToken)

        // Past the access token's hour, short of the refresh token's lifetime.
        try await own.advanceClock(by: .seconds(2 * 3600))
        let after = try await copy.items.create(note("written after the access token expired"))
        #expect(try await copy.queue.drain().verdicts.map(\.verdict) == [.accepted])
        let renewed = try #require(try authorization.place.read())
        #expect(renewed.accessToken != signedIn.accessToken)
        #expect(renewed.refreshToken != firstRefresh)
        #expect(try await read(try #require(after.itemId), own) == 200)
        #expect(try await read(try #require(before.itemId), own) == 200)

        // The owner revokes the app: the grant ends with its refresh token.
        try await revoke(try #require(renewed.refreshToken), clientId: renewed.clientId, own)
        try await own.advanceClock(by: .seconds(2 * 3600))
        _ = try await copy.items.create(note("written after the grant ended"))
        await #expect {
            try await copy.queue.drain()
        } throws: { error in
            guard case MarfaError.signedOut = error else { return false }
            return true
        }
        #expect(try authorization.place.read() == nil)
        #expect(throws: SignInError.notSignedIn) { try Server(url: own.url, credential: credential) }
        await copy.close()
    }

    private static func note(_ title: String) -> Draft {
        Draft(type: "core.note", properties: ["title": .string(title), "body": "b", "notes": "n"], tier: .library)
    }

    /// The owner's session cookie, as a `Cookie` header, from a password sign-in.
    private static func ownerCookie(_ own: OwnServer, _ session: URLSession) async throws -> String {
        let owner = try #require(own.owner, "the server printed no test owner")
        let origin = own.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var signIn = URLRequest(url: try #require(URL(string: "\(origin)/auth/sign-in/email")))
        signIn.httpMethod = "POST"
        signIn.setValue("application/json", forHTTPHeaderField: "Content-Type")
        signIn.setValue(origin, forHTTPHeaderField: "Origin")
        signIn.httpBody = try JSONSerialization.data(withJSONObject: ["email": owner.email, "password": owner.password])
        let (_, signedIn) = try await session.data(for: signIn)
        let response = try #require(signedIn as? HTTPURLResponse)
        try #require(response.statusCode == 200, "the owner could not sign in: \(response.statusCode)")
        let cookies = HTTPCookie.cookies(
            withResponseHeaderFields: response.allHeaderFields as? [String: String] ?? [:], for: own.url)
        let cookie = try #require(cookies.first { $0.name.hasSuffix("session_token") })
        return "\(cookie.name)=\(cookie.value)"
    }

    /// The owner approves every scope the app asked for, through the server's own approval page, as
    /// marfa's conformance suite does.
    private static func approve(_ userCode: String, on own: OwnServer) async throws {
        let origin = own.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let header = try await ownerCookie(own, session)

        var consent = URLComponents(string: "\(origin)/auth/device/consent")!
        consent.queryItems = [URLQueryItem(name: "user_code", value: userCode)]
        var page = URLRequest(url: try #require(consent.url))
        page.setValue(header, forHTTPHeaderField: "Cookie")
        let (html, shown) = try await session.data(for: page)
        try #require((shown as? HTTPURLResponse)?.statusCode == 200, "the approval page was refused")

        var form = URLComponents()
        form.queryItems =
            [URLQueryItem(name: "user_code", value: userCode), URLQueryItem(name: "decision", value: "approve")]
            + offered(String(decoding: html, as: UTF8.self), name: "scopes").map {
                URLQueryItem(name: "scopes", value: $0)
            }
        var approval = URLRequest(url: try #require(URL(string: "\(origin)/auth/device/consent")))
        approval.httpMethod = "POST"
        approval.setValue(header, forHTTPHeaderField: "Cookie")
        approval.setValue(origin, forHTTPHeaderField: "Origin")
        approval.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        approval.httpBody = Data(
            (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (_, approved) = try await session.data(for: approval)
        try #require((approved as? HTTPURLResponse)?.statusCode == 200, "the approval was refused")
    }

    /// The values the page offers under `name`: every input's value and every option of a select.
    private static func offered(_ html: String, name: String) -> [String] {
        var values: [String] = []
        let control = /<select\b[^>]*>[\s\S]*?<\/select>|<input\b[^>]*>/.ignoresCase()
        for match in html.matches(of: control) {
            let source = String(match.output)
            guard source.contains("name=\"\(name)\"") else { continue }
            let value = /value="([^"]*)"/
            for found in source.matches(of: value) where !found.output.1.isEmpty {
                let text = String(found.output.1)
                if !values.contains(text) { values.append(text) }
            }
        }
        return values
    }

    private static func revoke(_ refreshToken: String, clientId: String, _ own: OwnServer) async throws {
        let request = try formRequest(
            "\(own.url.absoluteString)/auth/oauth2/revoke",
            [("token", refreshToken), ("token_type_hint", "refresh_token"), ("client_id", clientId)])
        let (_, response) = try await URLSession.shared.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200, "the revocation was refused")
    }

    /// The status the server answers for the item, read with the server's own key past the copy.
    private static func read(_ id: String, _ own: OwnServer) async throws -> Int {
        var request = URLRequest(url: own.url.appending(path: "items/\(id)"))
        request.setValue("Bearer \(own.key)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

/// Hands a redirect back to the caller rather than following it.
private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
