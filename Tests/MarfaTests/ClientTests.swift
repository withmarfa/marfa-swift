import Foundation
import Testing

@testable import Marfa
@testable import MarfaAPI

private let service = "com.withmarfa.marfa-swift.tests"
private let contract = ["X-Marfa-Contract": String(marfaContractVersion)]
private let tags: ScriptedAuthServer.Reply = .raw(
    200, Data(#"{"data": [{"tag": "reading", "count": 2}], "next_cursor": null}"#.utf8),
    headers: contract.merging(["Content-Type": "application/json"]) { $1 })

private func refused(_ status: Int, _ code: String) -> ScriptedAuthServer.Reply {
    .json(status, ["error": ["code": code, "message": "scripted \(code)"]], headers: contract)
}

/// A client for `scripted` that sends `key`, with requests that never leave the process.
private func client(_ scripted: ScriptedAuthServer, timeout: Duration = .seconds(30)) -> Client {
    Client(
        Server(url: scripted.url, key: "marfa_k1_test"), through: scripted.transport().session, timeout: timeout)
}

/// A client signed in to `scripted` with the access token `at-1` and the refresh token `rt-1`.
private func signedIn(_ scripted: ScriptedAuthServer, _ keychain: Keychain) throws -> (Client, Authorization) {
    let authorization = try Authorization(
        server: scripted.url, client: .init(name: "Client tests", scopes: ["core.note:read"]), keychain: keychain,
        service: service, transport: scripted.transport())
    try authorization.place.keep(
        KeptSignIn(
            clientId: "client-1", grantTypes: ["refresh_token"], redirect: nil, accessToken: "at-1",
            refreshToken: "rt-1", scope: "core.note:read offline_access",
            tokenEndpoint: "\(scripted.origin)/auth/oauth2/token",
            revocationEndpoint: "\(scripted.origin)/auth/oauth2/revoke"))
    let credential = try #require(try authorization.credential())
    let server = try Server(url: scripted.url, credential: credential)
    return (Client(server, through: nil, timeout: .seconds(30)), authorization)
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
struct ClientTests {
    @Test func anOfflineDeviceThrowsNoConnection() async {
        let scripted = ScriptedAuthServer { _ in .failure(.notConnectedToInternet) }
        let error = await failure { try await client(scripted).listTags() }
        #expect(error?.code() == "no_connection", "\(String(describing: error))")
    }

    @Test func aRefusedAccessTokenIsRenewedOnceAndTheCallSentAgain() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer()
            scripted.answer { request in
                switch (request.path, request.headers["Authorization"]) {
                case ("/auth/oauth2/token", _):
                    .json(200, ["access_token": "at-2", "refresh_token": "rt-2", "token_type": "Bearer"])
                case (_, "Bearer at-2"): tags
                default: refused(401, "unauthorized")
                }
            }
            let (api, authorization) = try signedIn(scripted, keychain)
            let page = try await api.listTags().ok.body.json
            #expect(page.data.map(\.tag) == ["reading"])
            #expect(
                scripted.requests(to: "/metadata/tags").map { $0.headers["Authorization"] } == [
                    "Bearer at-1", "Bearer at-2",
                ])
            #expect(try authorization.credential()?.accessToken() == "at-2")
        }
    }

    @Test func aSignInTheServerEndedThrowsSignedOut() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { request in
                request.path == "/auth/oauth2/token"
                    ? .json(400, ["error": "invalid_grant", "error_description": "revoked"])
                    : refused(401, "unauthorized")
            }
            let (api, authorization) = try signedIn(scripted, keychain)
            let ended = await failure { try await api.listTags() }
            #expect(ended?.code() == "signed_out", "\(String(describing: ended))")
            #expect(try authorization.credential() == nil)

            // Once the keychain holds no sign-in, nothing is sent.
            let sent = scripted.requests.count
            let after = await failure { try await api.listTags() }
            #expect(after?.code() == "signed_out", "\(String(describing: after))")
            #expect(scripted.requests.count == sent)
        }
    }

    @Test func aCanceledCallThrowsCanceled() async {
        let hold = Hold()
        let scripted = ScriptedAuthServer { _ in .held(hold, tags) }
        let api = client(scripted)
        let call = Task { await failure { try await api.listTags() } }
        try? await eventually("the request is sent") { !scripted.requests.isEmpty }
        call.cancel()
        let error = await call.value
        hold.release()
        #expect(error?.code() == "canceled", "\(String(describing: error))")
    }

    @Test func aServerThatNeverAnswersTimesOut() async {
        let scripted = ScriptedAuthServer { _ in .silence }
        let error = await failure { try await client(scripted, timeout: .milliseconds(300)).listTags() }
        #expect(error == .network(message: "\(scripted.origin) did not answer in time"))
    }

    @Test func aSlowAnswerWithinTheTimeoutSucceeds() async throws {
        let scripted = ScriptedAuthServer { _ in .delayed(.milliseconds(300), tags) }
        let answer = try await client(scripted, timeout: .seconds(5)).listTags()
        _ = try answer.ok
    }

    @Test func aRedirectIsNotFollowedAndTheTokenGoesNowhereElse() async {
        let target = ScriptedAuthServer { _ in tags }
        let scripted = ScriptedAuthServer { _ in .raw(302, Data(), headers: ["Location": target.url.absoluteString]) }
        let error = await failure { try await client(scripted).listTags() }
        guard case .redirected(let origin, let status, let location, _)? = error else {
            Issue.record("\(String(describing: error))")
            return
        }
        #expect((origin, status, location) == (scripted.origin, 302, target.url.absoluteString))
        #expect(scripted.requests.count == 1)
        #expect(target.requests.isEmpty)
    }

    @Test func untidyRefusalsAreReadAsTheWorkingCopyReadsThem() async {
        let answers: [(ScriptedAuthServer.Reply, MarfaError)] = [
            (
                .raw(500, Data("<html>oops</html>".utf8), headers: contract),
                .server(status: 500, code: "unknown", message: "<html>oops</html>")
            ),
            (.raw(404, Data(), headers: contract), .notFound(code: "unknown", message: "")),
            (.raw(422, Data("{\"error\": 3}".utf8), headers: contract), .validation(code: "unknown", message: "")),
            (
                refused(403, "type_not_permitted"),
                .forbidden(code: "type_not_permitted", message: "scripted type_not_permitted")
            ),
            (.raw(502, Data("bad gateway".utf8)), .unnamed(status: 502, message: "")),
            (
                .raw(302, Data(), headers: ["Location": "https://elsewhere.example/"]),
                .redirected(origin: "", status: 302, location: "https://elsewhere.example/", message: "")
            ),
            (
                .raw(200, Data("{}".utf8), headers: ["X-Marfa-Contract": "999"]),
                .contractMismatch(
                    served: "999", expected: UInt64(marfaContractVersion), status: 200, writeSent: false, message: "")
            ),
        ]
        for (reply, expected) in answers {
            let scripted = ScriptedAuthServer { _ in reply }
            let error = await failure { try await client(scripted).listTags() }
            switch (error, expected) {
            case (
                .server(let status, let code, let message)?,
                .server(status: let wanted, code: let wantedCode, message: let wantedMessage)
            ):
                #expect((status, code, message) == (wanted, wantedCode, wantedMessage))
            case (.notFound(let code, let message)?, .notFound(let wantedCode, _)):
                #expect(code == wantedCode)
                #expect(message == "\(scripted.origin) answered 404")
            case (.redirected(let origin, _, let location, _)?, .redirected(_, _, let wanted, _)):
                #expect(origin == scripted.origin)
                #expect(location == wanted)
            default:
                #expect(error?.code() == expected.code(), "\(String(describing: error))")
            }
        }
    }
}
