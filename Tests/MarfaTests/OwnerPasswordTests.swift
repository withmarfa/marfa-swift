import Foundation
import Testing

@testable import Marfa
@testable import MarfaAPI

private let service = "com.withmarfa.marfa-swift.tests"
private let contract = ["X-Marfa-Contract": String(marfaContractVersion)]
private let jsonHeaders = contract.merging(["Content-Type": "application/json"]) { $1 }

private let signIns: ScriptedAuthServer.Reply = .raw(
    200, Data(#"{"data": [], "next_cursor": null}"#.utf8), headers: jsonHeaders)
private let changed: ScriptedAuthServer.Reply = .raw(200, Data(#"{"ok": true}"#.utf8), headers: jsonHeaders)

private func refused(
    _ status: Int, _ code: String, details: [String: any Sendable]? = nil, headers: [String: String] = [:]
) -> ScriptedAuthServer.Reply {
    var error: [String: any Sendable] = ["code": code, "message": "scripted \(code)"]
    if let details { error["details"] = details }
    return .json(status, ["error": error], headers: contract.merging(headers) { $1 })
}

private func client(_ scripted: ScriptedAuthServer) -> Client {
    Client(
        try! Server(url: scripted.url, key: "marfa_k1_test"), through: scripted.transport().session,
        timeout: .seconds(30))
}

/// A client signed in with the access token `at-1` and the refresh token `rt-1`.
private func signedIn(_ scripted: ScriptedAuthServer, _ keychain: Keychain) throws -> Client {
    let authorization = try Authorization(
        server: scripted.url, client: .init(name: "Password tests", scopes: ["core.note:read"]), keychain: keychain,
        service: service, transport: scripted.transport())
    try authorization.place.keep(
        KeptSignIn(
            clientId: "client-1", grantTypes: ["refresh_token"], redirect: nil, accessToken: "at-1",
            refreshToken: "rt-1", scope: "core.note:read offline_access",
            tokenEndpoint: "\(scripted.origin)/oauth/token",
            revocationEndpoint: "\(scripted.origin)/oauth/revoke"))
    let server = try Server(url: scripted.url, credential: #require(try authorization.credential()))
    return Client(server, through: nil, timeout: .seconds(30))
}

@Suite(.timeLimit(.minutes(1)))
struct OwnerPasswordTests {
    @Test func theRightCurrentPasswordChangesItAndSendsExactlyTheTwoFields() async throws {
        let scripted = ScriptedAuthServer()
        scripted.answer { $0.path == "/owner/password" ? changed : signIns }
        let outcome = try await client(scripted).changePassword(from: "old password", to: "new password")
        #expect(outcome == .changed)
        let sent = try #require(scripted.requests(to: "/owner/password").first)
        #expect(sent.method == "PUT")
        let body = try JSONDecoder().decode([String: String].self, from: sent.body)
        #expect(body == ["current_password": "old password", "new_password": "new password"])
    }

    @Test func aWrongCurrentPasswordIsToldApartAndIsSentOnce() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer()
            scripted.answer { $0.path == "/owner/password" ? refused(401, "unauthorized") : signIns }
            let outcome = try await signedIn(scripted, keychain).changePassword(from: "wrong", to: "new password")
            guard case .currentPasswordWrong = outcome else {
                Issue.record("expected currentPasswordWrong, got \(outcome)")
                return
            }
            // A second send would spend a second attempt of the owner's lockout.
            #expect(scripted.requests(to: "/owner/password").count == 1)
            #expect(scripted.requests(to: "/oauth/token").isEmpty)
        }
    }

    @Test func aNewPasswordTheServerRefusesIsToldApart() async throws {
        let scripted = ScriptedAuthServer()
        scripted.answer { $0.path == "/owner/password" ? refused(400, "validation_error") : signIns }
        let outcome = try await client(scripted).changePassword(from: "old password", to: "short")
        guard case .newPasswordRefused(let message) = outcome else {
            Issue.record("expected newPasswordRefused, got \(outcome)")
            return
        }
        #expect(message == "scripted validation_error")
    }

    @Test func aCredentialWithoutSignInsManageIsToldWhichPermissionItLacksAndNoPasswordIsSent() async throws {
        let scripted = ScriptedAuthServer()
        scripted.answer { _ in refused(403, "forbidden", details: ["required_scope": "sign_ins.manage"]) }
        let outcome = try await client(scripted).changePassword(from: "old password", to: "new password")
        guard case .notPermitted(let scope, _) = outcome else {
            Issue.record("expected notPermitted, got \(outcome)")
            return
        }
        #expect(scope == "sign_ins.manage")
        #expect(scripted.requests(to: "/owner/password").isEmpty)
    }

    @Test func aRefusalOfTheChangeItselfNamesThePermissionToo() async throws {
        let scripted = ScriptedAuthServer()
        scripted.answer {
            $0.path == "/owner/password"
                ? refused(403, "forbidden", details: ["required_scope": "sign_ins.manage"]) : signIns
        }
        let outcome = try await client(scripted).changePassword(from: "old password", to: "new password")
        guard case .notPermitted(let scope, _) = outcome else {
            Issue.record("expected notPermitted, got \(outcome)")
            return
        }
        #expect(scope == "sign_ins.manage")
    }

    @Test func tooManyPasswordsIsToldApartWithTheWait() async throws {
        let scripted = ScriptedAuthServer()
        scripted.answer {
            $0.path == "/owner/password" ? refused(429, "rate_limited", headers: ["Retry-After": "120"]) : signIns
        }
        let outcome = try await client(scripted).changePassword(from: "old password", to: "new password")
        #expect(outcome == .tooManyAttempts(retryAfterSeconds: 120))
    }

    @Test func aServerThatDoesNotAnswerThrowsAndSendsNothingMore() async throws {
        let scripted = ScriptedAuthServer { _ in .failure(.notConnectedToInternet) }
        let error = await #expect(throws: MarfaError.self) {
            try await client(scripted).changePassword(from: "old password", to: "new password")
        }
        #expect(error?.code() == "no_connection", "\(String(describing: error))")
        #expect(scripted.requests(to: "/owner/password").isEmpty)
    }

    @Test func anExpiredAccessTokenIsRenewedBeforeThePasswordIsSent() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer()
            scripted.answer { request in
                switch (request.path, request.headers["Authorization"]) {
                case ("/oauth/token", _):
                    .json(200, ["access_token": "at-2", "refresh_token": "rt-2", "token_type": "Bearer"])
                case (_, "Bearer at-2"): request.path == "/owner/password" ? changed : signIns
                default: refused(401, "unauthorized")
                }
            }
            let outcome = try await signedIn(scripted, keychain).changePassword(from: "old", to: "new password")
            #expect(outcome == .changed)
            let sends = scripted.requests(to: "/owner/password")
            #expect(sends.count == 1)
            #expect(sends.first?.headers["Authorization"] == "Bearer at-2")
        }
    }

    @Test func aTokenTheServerRefusesAtTheCheckIsAnErrorNotAWrongPassword() async throws {
        let scripted = ScriptedAuthServer()
        scripted.answer { _ in refused(401, "unauthorized") }
        let error = await #expect(throws: MarfaError.self) {
            try await client(scripted).changePassword(from: "old password", to: "new password")
        }
        #expect(error?.code() == "unauthorized", "\(String(describing: error))")
        #expect(scripted.requests(to: "/owner/password").isEmpty)
    }
}
