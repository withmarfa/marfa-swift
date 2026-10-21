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

    private static func run(_ own: OwnServer, _ keychain: Keychain) async throws {
        let authorization = Authorization(
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

    /// The owner approves every scope the app asked for, through the server's own approval page, as
    /// marfa's conformance suite does.
    private static func approve(_ userCode: String, on own: OwnServer) async throws {
        let owner = try #require(own.owner, "the server printed no test owner")
        let origin = own.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

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
        let header = "\(cookie.name)=\(cookie.value)"

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
