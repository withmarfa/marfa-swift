import Foundation
import Synchronization
import Testing

@testable import Marfa
@testable import MarfaAPI

private func client(_ scripted: ScriptedAuthServer) -> Client {
    Client(
        Server(url: scripted.url, key: "marfa_k1_test"), through: scripted.transport().session,
        timeout: .seconds(30))
}

@Suite(.timeLimit(.minutes(1)))
struct ContractHeaderTests {
    @Test(arguments: [
        ("GET", "/", nil), ("GET", "", nil), ("GET", "/health", nil), ("GET", "/health?probe=1", nil),
        ("GET", "/tags", String(marfaContractVersion)), ("GET", "/healthy", String(marfaContractVersion)),
        ("POST", "/", String(marfaContractVersion)), ("POST", "/health", String(marfaContractVersion)),
        ("DELETE", "/types/app.x.t", String(marfaContractVersion)),
    ])
    func everyRequestNamesTheContractButTheRootAndHealthReads(method: String, path: String, sent: String?) {
        #expect(ContractHeader.value(method: method, path: path) == sent)
    }

    @Test func aGeneratedClientCallSendsTheContract() async throws {
        let scripted = ScriptedAuthServer { _ in
            .raw(
                200, Data(#"{"data": [], "next_cursor": null}"#.utf8),
                headers: ["Content-Type": "application/json", "X-Marfa-Contract": String(marfaContractVersion)])
        }
        _ = try await client(scripted).listTags()
        let sent = try #require(scripted.requests(to: "/tags").first)
        #expect(sent.headers["X-Marfa-Contract"] == String(marfaContractVersion))
    }

    @Test func aServerRefusalBeforeItActedIsAContractMismatchThatSentNothing() async {
        let scripted = ScriptedAuthServer { _ in
            .json(
                412, ["error": ["code": "contract_mismatch", "message": "This server speaks contract 2."]],
                headers: ["X-Marfa-Contract": "2", "X-Error-Code": "contract_mismatch"])
        }
        do {
            _ = try await client(scripted).listTags()
            Issue.record("a 412 contract_mismatch was taken as success")
        } catch let error as MarfaError {
            guard case .contractMismatch(let served, let expected, let status, let writeSent, _, let answer) = error
            else {
                Issue.record("expected contract_mismatch, got \(error)")
                return
            }
            #expect(served == "2")
            #expect(expected == UInt64(marfaContractVersion))
            #expect(status == 412)
            #expect(!writeSent)
            #expect(answer?.code == "contract_mismatch")
        } catch {
            Issue.record("expected a MarfaError, got \(error)")
        }
    }
}

private let service = "com.withmarfa.marfa-swift.tests"

/// A server signed in to `scripted` with the access token `at-1`, whose requests never leave the process.
private func signedIn(_ scripted: ScriptedAuthServer, _ keychain: Keychain) throws -> Server {
    let authorization = try Authorization(
        server: scripted.url, client: .init(name: "Contract tests", scopes: ["core.note:read"]),
        keychain: keychain, service: service, transport: scripted.transport())
    try authorization.place.keep(
        KeptSignIn(
            clientId: "client-1", grantTypes: ["refresh_token"], redirect: nil, accessToken: "at-1",
            refreshToken: "rt-1", scope: "core.note:read offline_access",
            tokenEndpoint: "\(scripted.origin)/oauth/token",
            revocationEndpoint: "\(scripted.origin)/oauth/revoke"))
    return try Server(url: scripted.url, credential: #require(try authorization.credential()))
}

/// The server calls' own transport, through the real request path.
@Suite(.timeLimit(.minutes(1)))
struct ServerTransportContractHeader {
    private let contract = String(marfaContractVersion)

    private func ok(_ body: String = "{}") -> ScriptedAuthServer.Reply {
        .raw(
            200, Data(body.utf8),
            headers: ["Content-Type": "application/json", "X-Marfa-Contract": String(marfaContractVersion)])
    }

    @Test(arguments: ["GET", "PUT", "PATCH", "DELETE", "POST"])
    func aRequestOtherThanARootOrHealthReadNamesTheContract(method: String) async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in ok() }
            let server = try signedIn(scripted, keychain)
            _ = try await server.send(method, "/config", body: nil, timeout: .seconds(30))
            let sent = try #require(scripted.requests(to: "/config").first)
            #expect(sent.method == method)
            #expect(sent.headers["X-Marfa-Contract"] == contract)
        }
    }

    @Test func aServerCallNamesTheContract() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in ok(#"{"data": [], "next_cursor": null}"#) }
            let server = try signedIn(scripted, keychain)
            _ = try await server.snapshots(ofItem: "i1", after: nil, limit: 2)
            let sent = try #require(scripted.requests(to: "/items/i1/versions").first)
            #expect(sent.headers["X-Marfa-Contract"] == contract)
        }
    }

    @Test(arguments: ["/", "/health"])
    func aReadOfTheRootOrHealthSendsNoContract(path: String) async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in ok() }
            let server = try signedIn(scripted, keychain)
            _ = try await server.send("GET", path, timeout: .seconds(30))
            let sent = try #require(scripted.requests.first { $0.path == path })
            #expect(sent.headers["X-Marfa-Contract"] == nil)
            // The witness: any other path, through the same code, does send it.
            _ = try await server.send("GET", "/x", timeout: .seconds(30))
            let other = try #require(scripted.requests(to: "/x").first)
            #expect(other.headers["X-Marfa-Contract"] == contract)
        }
    }

    @Test func aRenewedRequestNamesTheContractAgain() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer()
            let calls = Mutex(0)
            let tokens = ScriptedAuthServer.Reply.json(
                200, ["access_token": "at-2", "refresh_token": "rt-2", "token_type": "Bearer", "expires_in": 3600])
            scripted.answer { request in
                if request.path == "/oauth/token" { return tokens }
                let first = calls.withLock {
                    $0 += 1
                    return $0 == 1
                }
                return first
                    ? .json(
                        401, ["error": ["code": "invalid_token", "message": "expired"]],
                        headers: ["X-Marfa-Contract": String(marfaContractVersion)])
                    : ok()
            }
            let server = try signedIn(scripted, keychain)
            _ = try await server.send("PATCH", "/config", body: Data("{}".utf8), timeout: .seconds(30))
            let sent = scripted.requests(to: "/config")
            #expect(sent.map { $0.headers["Authorization"] } == ["Bearer at-1", "Bearer at-2"])
            #expect(sent.allSatisfy { $0.headers["X-Marfa-Contract"] == contract })
            #expect(scripted.requests(to: "/oauth/token").first?.headers["X-Marfa-Contract"] == contract)
        }
    }

    @Test func aWriteTheServerRefusesForTheContractBeforeItActedSentNothing() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in
                .json(
                    412, ["error": ["code": "contract_mismatch", "message": "This server speaks contract 2."]],
                    headers: ["X-Marfa-Contract": "2", "X-Error-Code": "contract_mismatch"])
            }
            let server = try signedIn(scripted, keychain)
            do {
                _ = try await server.setTypeIcon("lucide:book-open", ofType: "core.note")
                Issue.record("a 412 contract_mismatch was taken as success")
            } catch {
                guard case .contractMismatch(let served, let expected, let status, let writeSent, _, let answer) = error
                else {
                    Issue.record("expected contract_mismatch, got \(error)")
                    return
                }
                #expect(served == "2")
                #expect(expected == UInt64(marfaContractVersion))
                #expect(status == 412)
                #expect(!writeSent)
                #expect(answer?.code == "contract_mismatch")
            }
            let sent = try #require(scripted.requests(to: "/types/core.note/icon").first)
            #expect(sent.method == "PUT")
            #expect(scripted.requests.count == 1)
        }
    }

    @Test func aWriteAnsweredOnAnotherContractWithNoRefusalMayHaveActed() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in
                .raw(200, Data("{}".utf8), headers: ["X-Marfa-Contract": "2"])
            }
            let server = try signedIn(scripted, keychain)
            do {
                _ = try await server.setTypeIcon("lucide:book-open", ofType: "core.note")
                Issue.record("an answer on another contract was taken as success")
            } catch {
                guard case .contractMismatch(_, _, _, let writeSent, _, _) = error else {
                    Issue.record("expected contract_mismatch, got \(error)")
                    return
                }
                #expect(writeSent)
            }
        }
    }
}
