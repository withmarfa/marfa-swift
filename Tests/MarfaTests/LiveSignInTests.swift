import Foundation
import Testing

@testable import Marfa

/// Signs in to a server of its own with the device grant, as an app without a browser does, and follows the
/// sign-in through an access token the server stops accepting, a renewal, and a grant the server ends.
///
/// The server is the release's own, with no test hooks: the owner revokes the access token to make the server
/// refuse it, as it does once the token's hour has passed.
@Suite(
    .serialized,
    .enabled(if: OwnServer.monorepo != nil, "set MARFA_MONOREPO to a marfa checkout whose server is built"),
    .timeLimit(.minutes(5)))
struct LiveSignIn {
    static let service = "com.withmarfa.marfa-swift.tests"

    @Test func aDeviceSignInWritesRenewsAndEndsWhenTheGrantIsRevoked() async throws {
        let own = try await OwnServer.boot()
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

        // Another device sign-in registers a client of its own too, and ends the grant it replaces.
        let again = try await authorization.startDeviceSignIn()
        try await approve(again.userCode, on: own)
        #expect(try await again.credential().replacedGrantStands == false)
        let second = try #require(try authorization.place.read())
        #expect(second.clientId != device.clientId)
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

    /// The client of every grant the owner approved, as `GET /grants` lists them.
    private static func grants(_ own: OwnServer) async throws -> [String] {
        var request = URLRequest(url: own.url.appending(path: "grants"))
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
    static func browserApproval(on own: OwnServer) -> @MainActor @Sendable (URL, String) async throws -> URL {
        { authorize, scheme in
            let origin = own.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let cookie = try await ownerCookie(own, session)
            var asked = URLRequest(url: authorize)
            asked.setValue(cookie, forHTTPHeaderField: "Cookie")
            var landed = try await sentTo(asked, session, own)
            if landed.scheme != scheme {
                var page = URLRequest(url: landed)
                page.setValue(cookie, forHTTPHeaderField: "Cookie")
                let (html, shown) = try await session.data(for: page, delegate: NoRedirect())
                try #require((shown as? HTTPURLResponse)?.statusCode == 200, "the consent screen was refused")
                var form = URLComponents()
                form.queryItems =
                    [
                        URLQueryItem(name: "decision", value: "approve"),
                        URLQueryItem(name: "authorization_request", value: landed.query()),
                    ] + asDrawn(String(decoding: html, as: UTF8.self))
                var decision = URLRequest(url: try #require(URL(string: "\(origin)/auth/consent")))
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

        // The server stops accepting the access token, as it does after the token's hour.
        try await revoke(signedIn.accessToken, hint: "access_token", clientId: signedIn.clientId, own)
        #expect(try await itemsStatus(signedIn.accessToken, own) == 401)
        let after = try await copy.items.create(note("written after the access token expired"))
        #expect(try await copy.queue.drain().verdicts.map(\.verdict) == [.accepted])
        let renewed = try #require(try authorization.place.read())
        #expect(renewed.accessToken != signedIn.accessToken)
        #expect(renewed.refreshToken != firstRefresh)
        #expect(try await read(try #require(after.itemId), own) == 200)
        #expect(try await read(try #require(before.itemId), own) == 200)

        // The owner revokes the app: the grant ends with its refresh token.
        try await revoke(try #require(renewed.refreshToken), hint: "refresh_token", clientId: renewed.clientId, own)
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
        var signIn = URLRequest(url: try #require(URL(string: "\(origin)/auth/sign-in")))
        signIn.httpMethod = "POST"
        signIn.setValue("application/json", forHTTPHeaderField: "Content-Type")
        signIn.setValue(origin, forHTTPHeaderField: "Origin")
        signIn.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": owner.username, "password": owner.password,
        ])
        let (_, signedIn) = try await session.data(for: signIn)
        let response = try #require(signedIn as? HTTPURLResponse)
        try #require(response.statusCode == 200, "the owner could not sign in: \(response.statusCode)")
        let cookies = HTTPCookie.cookies(
            withResponseHeaderFields: response.allHeaderFields as? [String: String] ?? [:], for: own.url)
        let cookie = try #require(cookies.first { $0.name == "marfa_session" })
        return "\(cookie.name)=\(cookie.value)"
    }

    /// The owner approves every scope the app asked for, through the server's own approval page, as
    /// marfa's conformance suite does.
    private static func approve(_ userCode: String, on own: OwnServer) async throws {
        let origin = own.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let header = try await ownerCookie(own, session)

        // The owner first confirms the code matches the device's, which opens the approval page to this
        // browser session only.
        var checked = URLComponents()
        checked.queryItems = [URLQueryItem(name: "user_code", value: userCode)]
        var check = URLRequest(url: try #require(URL(string: "\(origin)/auth/device/check")))
        check.httpMethod = "POST"
        check.setValue(header, forHTTPHeaderField: "Cookie")
        check.setValue(origin, forHTTPHeaderField: "Origin")
        check.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        check.httpBody = Data((checked.percentEncodedQuery ?? "").utf8)
        let (_, confirmed) = try await session.data(for: check, delegate: NoRedirect())
        let sent = (confirmed as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") ?? ""
        try #require(
            (confirmed as? HTTPURLResponse)?.statusCode == 302
                && URL(string: sent, relativeTo: own.url)?.path() == "/auth/device/consent",
            "the check of the device code was refused: \(sent)")

        var consent = URLComponents(string: "\(origin)/auth/device/consent")!
        consent.queryItems = [URLQueryItem(name: "user_code", value: userCode)]
        var page = URLRequest(url: try #require(consent.url))
        page.setValue(header, forHTTPHeaderField: "Cookie")
        let (html, shown) = try await session.data(for: page, delegate: NoRedirect())
        try #require((shown as? HTTPURLResponse)?.statusCode == 200, "the approval page was refused")

        var form = URLComponents()
        form.queryItems =
            [URLQueryItem(name: "user_code", value: userCode), URLQueryItem(name: "decision", value: "approve")]
            + asDrawn(String(decoding: html, as: UTF8.self))
        var approval = URLRequest(url: try #require(URL(string: "\(origin)/auth/device/consent")))
        approval.httpMethod = "POST"
        approval.setValue(header, forHTTPHeaderField: "Cookie")
        approval.setValue(origin, forHTTPHeaderField: "Origin")
        approval.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        approval.httpBody = Data(
            (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (_, approved) = try await session.data(for: approval, delegate: NoRedirect())
        try #require((approved as? HTTPURLResponse)?.statusCode == 200, "the approval was refused")
    }

    /// What an approval page's form posts when the owner changes nothing on it: each hidden field, and each
    /// pop-up at its selected option, or its first. The page starts every choice at the most the request names,
    /// so this approves everything the app asked for.
    private static func asDrawn(_ html: String) -> [URLQueryItem] {
        let fields: Set = ["held", "scopes", "types", "admin", "powers"]
        var posted: [URLQueryItem] = []
        let control = /<select\b[^>]*>[\s\S]*?<\/select>|<input\b[^>]*>/.ignoresCase()
        for match in html.matches(of: control) {
            let source = String(match.output)
            let opening = source.prefix { $0 != ">" }
            guard let name = opening.firstMatch(of: /name="([^"]*)"/).map({ String($0.output.1) }),
                fields.contains(name), !opening.contains(" disabled")
            else { continue }
            let value: String?
            if source.lowercased().hasPrefix("<select") {
                let options = source.matches(of: /<option\b([^>]*)>/).map { String($0.output.1) }
                let chosen = options.first { $0.contains(" selected") } ?? options.first
                value = chosen?.firstMatch(of: /value="([^"]*)"/).map { String($0.output.1) }
            } else {
                guard opening.contains("type=\"hidden\"") else { continue }
                value = opening.firstMatch(of: /value="([^"]*)"/).map { String($0.output.1) }
            }
            if let value, !value.isEmpty {
                posted.append(URLQueryItem(name: name, value: value.replacingOccurrences(of: "&amp;", with: "&")))
            }
        }
        return posted
    }

    private static func revoke(_ token: String, hint: String, clientId: String, _ own: OwnServer) async throws {
        let request = try formRequest(
            "\(own.url.absoluteString)/oauth/revoke",
            [("token", token), ("token_type_hint", hint), ("client_id", clientId)])
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

/// What an open copy does when its sign-in changes under it.
extension LiveSignIn {
    static func authorization(_ own: OwnServer, _ keychain: Keychain, service: String) throws -> Authorization {
        try Authorization(
            server: own.url,
            client: Authorization.Client(
                name: "marfa-swift live tests", redirect: URL(string: "com.withmarfa.marfa-swift.tests:/signed-in"),
                scopes: ["core.note:read", "core.note:write"]),
            keychain: keychain, service: service)
    }

    static func deviceSignIn(_ authorization: Authorization, _ own: OwnServer) async throws -> Credential {
        let started = try await authorization.startDeviceSignIn()
        try await approve(started.userCode, on: own)
        return try await started.credential()
    }

    static func drained(_ copy: WorkingCopy, _ title: String) async throws {
        _ = try await copy.items.create(Self.note(title))
        #expect(try await copy.queue.drain().verdicts.map(\.verdict) == [.accepted])
    }

    @Test func aCopyWhoseGrantEndedFollowsAgainWithANewSignInGivenToUse() async throws {
        let own = try await OwnServer.boot()
        do {
            try await inIsolatedKeychainAsync { keychain, _ async throws in
                let authorization = try Self.authorization(own, keychain, service: Self.service)
                let first = try await Self.deviceSignIn(authorization, own)
                let copy = try await WorkingCopy.open(
                    store: temporaryStore(), server: try Server(url: own.url, credential: first))
                _ = try await copy.hydrate(types: ["core.note"], tier: .library)
                let updates = Updates(copy.updates())
                try await eventually("following") { updates.connection == .following }
                try await Self.drained(copy, "written before the grant ended")

                // The owner revokes the app: the grant ends with its refresh token.
                let kept = try #require(try authorization.place.read())
                try await Self.revoke(kept.accessToken, hint: "access_token", clientId: kept.clientId, own)
                let refresh = try #require(kept.refreshToken)
                try await Self.revoke(refresh, hint: "refresh_token", clientId: kept.clientId, own)
                let waiting = try await copy.items.create(Self.note("queued while signed out"))
                await #expect {
                    try await copy.queue.drain()
                } throws: { error in
                    guard case MarfaError.signedOut = error else { return false }
                    return true
                }
                try await eventually("the copy shows its key refused") {
                    if case .keyRefused? = updates.connection { true } else { false }
                }

                // The app signs in again and hands the copy the new sign-in; the same copy goes on.
                let left = try authorization.place.read()
                // It is a separate sign-in, kept in its own keychain item, so a renewal can tell which one it read.
                let replacement = try Self.authorization(own, keychain, service: Self.service + ".replacement")
                let second = try await Self.deviceSignIn(replacement, own)
                try await bounded("use") { try await copy.use(try Server(url: own.url, credential: second)) }
                // A sign-in is a new reach, so the copy is filled again from the server and keeps its queue.
                try await eventually("the copy asks to be hydrated") {
                    if case .needsHydration? = updates.connection { true } else { false }
                }
                _ = try await copy.hydrate(types: ["core.note"], tier: .library)
                try await eventually("following again") { updates.connection == .following }
                #expect(try await copy.queue.drain().verdicts.map(\.verdict) == [.accepted])
                #expect(try await Self.read(try #require(waiting.itemId), own) == 200)

                // A renewal after the swap goes through the new sign-in.
                let signedIn = try #require(try replacement.place.read())
                try await Self.revoke(signedIn.accessToken, hint: "access_token", clientId: signedIn.clientId, own)
                try await Self.drained(copy, "written after a renewal under the new sign-in")
                let renewed = try #require(try replacement.place.read())
                #expect(renewed.accessToken != signedIn.accessToken)
                #expect(renewed.refreshToken != signedIn.refreshToken)
                #expect(try authorization.place.read() == left, "the renewal read the sign-in the copy left")
                await copy.close()
            }
        } catch {
            try await own.end()
            throw error
        }
        try await own.end()
    }

    @Test func aCopyMovesFromAKeyToACredentialAndBack() async throws {
        let own = try await OwnServer.boot()
        do {
            try await inIsolatedKeychainAsync { keychain, _ async throws in
                let authorization = try Self.authorization(own, keychain, service: Self.service)
                let copy = try await WorkingCopy.open(store: temporaryStore(), server: own.server)
                _ = try await copy.hydrate(types: ["core.note"], tier: .library)
                try await Self.drained(copy, "written with the key")

                let credential = try await Self.deviceSignIn(authorization, own)
                try await copy.use(try Server(url: own.url, credential: credential))
                _ = try await copy.hydrate(types: ["core.note"], tier: .library)
                try await Self.drained(copy, "written with the sign-in")
                let signedIn = try #require(try authorization.place.read())
                try await Self.revoke(signedIn.accessToken, hint: "access_token", clientId: signedIn.clientId, own)
                try await Self.drained(copy, "written after the sign-in renewed")
                #expect(try authorization.place.read()?.accessToken != signedIn.accessToken)

                // Back to a key: nothing renews, and the sign-in the copy left is not touched.
                let left = try #require(try authorization.place.read())
                try await copy.use(own.server)
                _ = try await copy.hydrate(types: ["core.note"], tier: .library)
                try await Self.drained(copy, "written with the key again")
                #expect(try authorization.place.read()?.accessToken == left.accessToken)
                await copy.close()
            }
        } catch {
            try await own.end()
            throw error
        }
        try await own.end()
    }

    @Test func aCopyRefusesAServerAtAnotherAddressAndChangesNothing() async throws {
        let own = try await OwnServer.boot()
        do {
            let copy = try await WorkingCopy.open(store: temporaryStore(), server: own.server)
            _ = try await copy.hydrate(types: ["core.note"], tier: .library)
            let updates = Updates(copy.updates())
            try await eventually("following") { updates.connection == .following }
            let count = updates.all.count
            let elsewhere = try Server(url: URL(string: "http://127.0.0.1:1")!, key: "other")
            await #expect {
                try await copy.use(elsewhere)
            } throws: { error in
                guard case MarfaError.wrongServer(let expected, let got, _) = error else { return false }
                return expected == origin(of: own.url) && got == "http://127.0.0.1:1"
            }
            #expect(updates.all.count == count, "a refused server changed the copy")
            try await Self.drained(copy, "written after the refusal")
            #expect(updates.connection == .following)
            await copy.close()
        } catch {
            try await own.end()
            throw error
        }
        try await own.end()
    }

    /// An owner who confirms a sign-in leaves the same credential holding new tokens; the open copy's renewal reads
    /// them, so the app does nothing.
    @Test func aConfirmedSignInOfTheSameCredentialReachesAnOpenCopyWithoutUse() async throws {
        let own = try await OwnServer.boot()
        do {
            try await inIsolatedKeychainAsync { keychain, _ async throws in
                let authorization = try Self.authorization(own, keychain, service: Self.service)
                let credential = try await authorization.signIn(browser: Self.browserApproval(on: own))
                let copy = try await WorkingCopy.open(
                    store: temporaryStore(), server: try Server(url: own.url, credential: credential))
                _ = try await copy.hydrate(types: ["core.note"], tier: .library)
                try await Self.drained(copy, "written before the confirmation")
                let before = try #require(try authorization.place.read())

                let confirmed = try await credential.reauthorization().signIn(
                    maxAge: 300, browser: Self.browserApproval(on: own))
                #expect(confirmed == credential)
                let after = try #require(try authorization.place.read())
                try await Self.revoke(before.accessToken, hint: "access_token", clientId: before.clientId, own)
                #expect(try await Self.itemsStatus(before.accessToken, own) == 401)

                try await Self.drained(copy, "written after the confirmation")
                #expect(
                    try authorization.place.read() == after,
                    "the copy renewed again instead of taking the confirmed sign-in")
                await copy.close()
            }
        } catch {
            try await own.end()
            throw error
        }
        try await own.end()
    }
}
