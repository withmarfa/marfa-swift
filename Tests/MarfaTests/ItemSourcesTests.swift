import Foundation
import MarfaTypes
import Testing

@testable import Marfa

private let service = "com.withmarfa.marfa-swift.tests"
private let contract = ["X-Marfa-Contract": String(marfaContractVersion)]
private let json = contract.merging(["Content-Type": "application/json"]) { $1 }

private func reply(_ text: String) -> ScriptedAuthServer.Reply {
    .raw(200, Data(text.utf8), headers: json)
}

private func signedIn(_ scripted: ScriptedAuthServer, _ keychain: Keychain) throws -> Server {
    let authorization = try Authorization(
        server: scripted.url, client: .init(name: "Source tests", scopes: ["core.note:read"]),
        keychain: keychain, service: service, transport: scripted.transport())
    try authorization.place.keep(
        KeptSignIn(
            clientId: "client-1", grantTypes: ["refresh_token"], redirect: nil, accessToken: "at-1",
            refreshToken: "rt-1", scope: "core.note:read offline_access",
            tokenEndpoint: "\(scripted.origin)/auth/oauth2/token",
            revocationEndpoint: "\(scripted.origin)/auth/oauth2/revoke"))
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

private func body(_ request: ScriptedAuthServer.Request) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
}

@Suite(.timeLimit(.minutes(1)))
struct ItemSourcesTests {
    @Test func sourcesListsEachWithItsNameOriginAndMark() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in
                reply(
                    """
                    {"data": [
                      {"source": "github", "name": "GitHub", "name_from": "set", "mark": "simple-icons:github"},
                      {"source": "k", "name": "Label", "name_from": "key"},
                      {"source": "x", "name": "x", "name_from": "future"}
                    ], "next_cursor": null}
                    """)
            }
            let sources = try await signedIn(scripted, keychain).sources()
            let request = try #require(scripted.requests(to: "/sources").first)
            #expect(request.method == "GET" && request.query == nil)
            #expect(request.headers["Authorization"] == "Bearer at-1")
            #expect(
                sources == [
                    ItemSource(code: "github", name: "GitHub", nameOrigin: .set, mark: "simple-icons:github"),
                    ItemSource(code: "k", name: "Label", nameOrigin: .key),
                    ItemSource(code: "x", name: "x", nameOrigin: .other("future")),
                ])
            #expect(sources[0].id == "github" && sources[0].nameOrigin.rawValue == "set")
        }
    }

    @Test func aSourceCodeTravelsInTheQueryWhateverItHolds() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in
                reply(#"{"source": "a/b?c#d+e ..", "name": "N", "name_from": "code"}"#)
            }
            let source = try await signedIn(scripted, keychain).source("a/b?c#d+e ..")
            #expect(source.code == "a/b?c#d+e .." && source.nameOrigin == .code && source.mark == nil)
            let request = try #require(scripted.requests(to: "/source").first)
            #expect(request.method == "GET")
            #expect(request.query?.contains("+") == false, "a server reads + in a query as a space")
            let sent = URLComponents(string: "?" + (request.query ?? ""))?.queryItems ?? []
            #expect(sent == [URLQueryItem(name: "source", value: "a/b?c#d+e ..")])
        }
    }

    @Test func aSourceTheKeyCannotSeeIsNotFound() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in
                .json(404, ["error": ["code": "source_not_found", "message": "no"]], headers: contract)
            }
            let error = await failure { try await signedIn(scripted, keychain).source("nope") }
            guard case .notFound(let code, _)? = error else {
                Issue.record("expected notFound, got \(String(describing: error))")
                return
            }
            #expect(code == "source_not_found")
        }
    }

    @Test func updateSendsOnlyTheFieldsChanged() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in
                reply(#"{"source": "s", "name": "Named", "name_from": "set"}"#)
            }
            let server = try signedIn(scripted, keychain)
            let source = try await server.updateSource("s", name: .set("Named"))
            #expect(source == ItemSource(code: "s", name: "Named", nameOrigin: .set))
            try await server.updateSource("s", mark: .set("lucide:book-open"))
            try await server.updateSource("s", name: .clear, mark: .clear)
            let requests = scripted.requests(to: "/source")
            #expect(requests.count == 3 && requests.allSatisfy { $0.method == "PATCH" && $0.query == "source=s" })
            #expect(try body(requests[0]) as NSDictionary == ["name": "Named"])
            #expect(try body(requests[1]) as NSDictionary == ["mark": "lucide:book-open"])
            #expect(try body(requests[2]) as NSDictionary == ["name": NSNull(), "mark": NSNull()])
        }
    }

    @Test func aRefusedChangeArrivesAsAMarfaError() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in
                .json(403, ["error": ["code": "forbidden", "message": "keys.manage"]], headers: contract)
            }
            let error = await failure {
                try await signedIn(scripted, keychain).updateSource("other", name: .set("X"))
            }
            guard case .forbidden(let code, _)? = error else {
                Issue.record("expected forbidden, got \(String(describing: error))")
                return
            }
            #expect(code == "forbidden")
        }
    }

    @Test func countsBySourceAskForTheGroupingAndTheFiltersGiven() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in reply(#"{"github": 12, "k": 1}"#) }
            let server = try signedIn(scripted, keychain)
            #expect(try await server.itemCountsBySource() == ["github": 12, "k": 1])
            _ = try await server.itemCountsBySource(
                type: "core.*", state: "active,archived", tier: .feed, filter: "a b")
            let requests = scripted.requests(to: "/items/stats")
            #expect(requests[0].query == "by=source")
            let sent = URLComponents(string: "?" + (requests[1].query ?? ""))?.queryItems ?? []
            #expect(
                sent == [
                    URLQueryItem(name: "by", value: "source"), URLQueryItem(name: "type", value: "core.*"),
                    URLQueryItem(name: "state", value: "active,archived"), URLQueryItem(name: "tier", value: "feed"),
                    URLQueryItem(name: "filter", value: "a b"),
                ])
        }
    }

    @Test func countsInAFormThisBuildCannotReadFailAsDecoding() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in reply(#"{"github": "many"}"#) }
            let error = await failure { try await signedIn(scripted, keychain).itemCountsBySource() }
            #expect(error?.code() == "decoding", "\(String(describing: error))")
        }
    }
}
