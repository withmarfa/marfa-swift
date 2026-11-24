import Foundation
import MarfaTypes
import Testing

@testable import Marfa

private let service = "com.withmarfa.marfa-swift.tests"
private let contract = ["X-Marfa-Contract": String(marfaContractVersion)]
private let id = "01939b7a-5c3e-7d2f-8a41-0123456789ab"

private func reply(_ text: String) -> ScriptedAuthServer.Reply {
    .raw(200, Data(text.utf8), headers: contract.merging(["Content-Type": "application/json"]) { $1 })
}

private func signedIn(_ scripted: ScriptedAuthServer, _ keychain: Keychain) throws -> Server {
    let authorization = try Authorization(
        server: scripted.url, client: .init(name: "Item links tests", scopes: ["core.note:read"]),
        keychain: keychain, service: service, transport: scripted.transport())
    try authorization.place.keep(
        KeptSignIn(
            clientId: "client-1", grantTypes: ["refresh_token"], redirect: nil, accessToken: "at-1",
            refreshToken: "rt-1", scope: "core.note:read offline_access",
            tokenEndpoint: "\(scripted.origin)/oauth/token",
            revocationEndpoint: "\(scripted.origin)/oauth/revoke"))
    return try Server(url: scripted.url, credential: #require(try authorization.credential()))
}

private func failure(_ call: () async throws -> some Any) async -> MarfaError? {
    do {
        _ = try await call()
        return nil
    } catch {
        return error as? MarfaError
    }
}

private func item(web: String, app: String) -> String {
    #"{"item": {"id": "\#(id)", "properties": {"title": "secret"}, "web_url": "\#(web)", "app_url": "\#(app)"}, "metadata": {"tags": []}}"#
}

@Suite(.timeLimit(.minutes(1)))
struct ItemLinksTests {
    @Test func theLinksAreReadWithOnlyTheKeyAndTheTrashIncluded() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let web = "https://marfa.example/i/\(id)"
            let app = "marfa://instance-1/\(id)"
            let scripted = ScriptedAuthServer { _ in reply(item(web: web, app: app)) }
            let links = try await signedIn(scripted, keychain).itemLinks(of: id)
            #expect(links == ItemLinks(web: URL(string: web)!, app: URL(string: app)!))
            let request = try #require(scripted.requests(to: "/items/\(id)").first)
            #expect(request.method == "GET" && request.query == "state=any" && request.body.isEmpty)
            #expect(request.headers["Authorization"] == "Bearer at-1")
            #expect(scripted.requests.count == 1)
        }
    }

    @Test(arguments: [
        "", "i1", "a/b", "../x", id.uppercased(), "01939b7a-5c3e-4d2f-8a41-0123456789ab",
        "01939b7a-5c3e-7d2f-ca41-0123456789ab", "\(id) ", "\(id)\n", "01939b7a5c3e7d2f8a410123456789ab",
    ])
    func anIDThatIsNotALowercaseUUIDv7IsRefusedBeforeAnyRequest(_ bad: String) async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in reply(item(web: "https://m.example/i/x", app: "marfa://i/x")) }
            let server = try signedIn(scripted, keychain)
            let error = await failure { try await server.itemLinks(of: bad) }
            guard case .invalid? = error else {
                Issue.record("expected invalid, got \(String(describing: error))")
                return
            }
            #expect(scripted.requests.isEmpty, "a refused ID sent a request")
        }
    }

    @Test(arguments: [
        ("ftp://marfa.example/i/x", "marfa://i/x"),
        ("https:///i/x", "marfa://i/x"),
        ("/i/x", "marfa://i/x"),
        ("not a url", "marfa://i/x"),
        ("marfa://i/x", "marfa://i/x"),
        ("https://marfa.example/i/x", "https://marfa.example/i/x"),
        ("https://marfa.example/i/x", ""),
    ])
    func anAnswerWithALinkOfTheWrongKindIsADecodingError(_ web: String, _ app: String) async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in reply(item(web: web, app: app)) }
            let error = await failure { try await signedIn(scripted, keychain).itemLinks(of: id) }
            guard case .decoding(let message)? = error else {
                Issue.record("expected decoding, got \(String(describing: error))")
                return
            }
            #expect(!message.contains("secret") && !message.contains("marfa.example"))
        }
    }

    @Test func anAnswerWithNoLinksIsADecodingError() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in reply(#"{"item": {"id": "\#(id)"}}"#) }
            let error = await failure { try await signedIn(scripted, keychain).itemLinks(of: id) }
            guard case .decoding? = error else {
                Issue.record("expected decoding, got \(String(describing: error))")
                return
            }
        }
    }

    @Test func aMissingItemIsNotFound() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in
                .json(404, ["error": ["code": "item_not_found", "message": "scripted"]], headers: contract)
            }
            let error = await failure { try await signedIn(scripted, keychain).itemLinks(of: id) }
            guard case .notFound(let code, _, _)? = error else {
                Issue.record("expected notFound, got \(String(describing: error))")
                return
            }
            #expect(code == "item_not_found")
        }
    }
}
