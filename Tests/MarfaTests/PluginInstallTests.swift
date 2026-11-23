import Foundation
import Testing

@testable import Marfa
@testable import MarfaAPI

private let contract = ["X-Marfa-Contract": String(marfaContractVersion)]

private func refused(_ status: Int, _ code: String, details: [String: any Sendable]? = nil)
    -> ScriptedAuthServer.Reply
{
    var error: [String: any Sendable] = ["code": code, "message": "scripted \(code)"]
    if let details { error["details"] = details }
    return .json(status, ["error": error], headers: contract)
}

private func installed(fingerprint: String) -> ScriptedAuthServer.Reply {
    .json(
        201,
        [
            "name": "reading", "title": "Reading", "description": "Keep what you read.", "mark": "lucide:book-open",
            "maker": "Acme", "marfa": "0.0.90", "version": "1.2.0", "types": ["common.reading"],
            "edge_types": [String](),
            "connector": NSNull(), "connector_host": NSNull(), "fingerprint": fingerprint,
            "installed_at": "2026-11-21T10:00:00.000Z",
            "installed_by": ["kind": "key", "id": "01a1011b-b5e5-7be6-8f3b-77492475b5a4", "name": "laptop"],
            "updated_at": "2026-11-21T10:00:00Z", "outcome": "installed",
        ], headers: contract)
}

private let service = "com.withmarfa.marfa-swift.tests"

/// Runs `body` with a server signed in to `scripted` with the access token `at-1`, whose requests never leave the
/// process.
private func withServer(
    _ scripted: ScriptedAuthServer, _ body: @Sendable (Server) async throws -> Void
) async throws {
    try await inIsolatedKeychainAsync { keychain, _ async throws in
        let authorization = try Authorization(
            server: scripted.url, client: .init(name: "Plugin install tests", scopes: ["schema:write"]),
            keychain: keychain, service: service, transport: scripted.transport())
        try authorization.place.keep(
            KeptSignIn(
                clientId: "client-1", grantTypes: ["refresh_token"], redirect: nil, accessToken: "at-1",
                refreshToken: "rt-1", scope: "schema:write offline_access",
                tokenEndpoint: "\(scripted.origin)/oauth/token",
                revocationEndpoint: "\(scripted.origin)/oauth/revoke"))
        try await body(try Server(url: scripted.url, credential: #require(try authorization.credential())))
    }
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
struct PluginInstallTests {
    /// Spacing and a key order a decoder would not give back, so only the bytes themselves match.
    private static let bytes = Data(
        "{ \"version\" :\t\"1.2.0\",\n\n   \"format\": 1,  \"name\": \"reading\", \"marfa\": \"0.0.90\" }\n".utf8)

    /// A complete bundle in the spacing a person writes.
    private static let full = Data(
        """
        {  "name": "reading",   "format": 1,
           "title": "Reading", "description": "Keep what you read.", "mark": "lucide:book-open", "maker": "Acme",
           "marfa": "0.0.90", "version": "1.2.0", "edge_types": [],
           "types": [ { "id": "common.reading", "description": "Anything read.", "fields": {} } ] }

        """.utf8)

    @Test func theBundleIsSentByteForByteAndTheAnswerIsRead() async throws {
        let scripted = ScriptedAuthServer { _ in installed(fingerprint: String(repeating: "ab", count: 32)) }
        try await withServer(scripted) { server in
            let answer = try await server.install(pluginBundle: Self.bytes)
            let sent = try #require(scripted.requests.first)
            #expect(scripted.requests.count == 1)
            #expect(sent.method == "POST" && sent.path == "/plugins")
            #expect(sent.body == Self.bytes)
            #expect(sent.headers["Content-Type"] == "application/json")
            #expect(sent.headers["Authorization"] == "Bearer at-1")
            #expect(sent.headers["X-Marfa-Contract"] == String(marfaContractVersion))
            #expect(sent.headers["X-Marfa-Instance-Id"] == nil)
            #expect(answer.name == "reading" && answer.outcome == .installed)
            #expect(answer.fingerprint == String(repeating: "ab", count: 32))
            #expect(answer.installedAt == Date(timeIntervalSince1970: 1_795_255_200))
            #expect(answer.updatedAt == answer.installedAt)
            #expect(answer.installedBy.value?.name == "laptop")
        }
    }

    @Test func theGeneratedCallSendsOtherBytesWhichIsWhyInstallSendsTheBundleAsGiven() async throws {
        let scripted = ScriptedAuthServer { _ in installed(fingerprint: String(repeating: "ab", count: 32)) }
        try await withServer(scripted) { server in
            let decoded = try JSONDecoder().decode(Components.Schemas.PluginBundle.self, from: Self.full)
            _ = try await Client(server, through: nil, timeout: .seconds(30)).installPlugin(body: .json(decoded))
            let sent = try #require(scripted.requests.first)
            #expect(sent.body != Self.full)
            try await server.install(pluginBundle: Self.full)
            #expect(scripted.requests.last?.body == Self.full)
        }
    }

    @Test func theInstanceTheCallExpectsIsSent() async throws {
        let scripted = ScriptedAuthServer { _ in installed(fingerprint: String(repeating: "cd", count: 32)) }
        try await withServer(scripted) { server in
            let instance = "01a1011b-b5e5-7be6-8f3b-77492475b5a4"
            try await server.install(pluginBundle: Self.bytes, expecting: instance)
            #expect(scripted.requests.first?.headers["X-Marfa-Instance-Id"] == instance)
        }
    }

    @Test func aPluginThatNeedsALaterServerIsToldApartWithBothReleases() async throws {
        let scripted = ScriptedAuthServer { _ in
            refused(409, "plugin_needs_newer_server", details: ["marfa": "0.0.200", "server": "0.0.100"])
        }
        try await withServer(scripted) { server in
            let error = await failure { try await server.install(pluginBundle: Self.bytes) }
            #expect(error?.pluginInstallRefusal == .needsNewerServer(marfa: "0.0.200", server: "0.0.100"))
            guard case .server(409, "plugin_needs_newer_server", _, _, _)? = error else {
                Issue.record("\(String(describing: error))")
                return
            }
            // The witness: another 409 is no such refusal.
            scripted.answer { _ in refused(409, "plugin_version_older") }
            let older = await failure { try await server.install(pluginBundle: Self.bytes) }
            #expect(older != nil && older?.pluginInstallRefusal == nil)
        }
    }

    @Test func anInstallOfGuidanceByAnAppIsToldApartFromOtherForbiddenRefusals() async throws {
        let scripted = ScriptedAuthServer { _ in refused(403, "forbidden", details: ["changes": ["guidance"]]) }
        try await withServer(scripted) { server in
            let error = await failure { try await server.install(pluginBundle: Self.bytes) }
            #expect(error?.pluginInstallRefusal == .carriesGuidance)
            guard case .forbidden("forbidden", _, _)? = error else {
                Issue.record("\(String(describing: error))")
                return
            }
            for other in [
                refused(403, "forbidden", details: ["required_scope": "schema.write"]),
                refused(403, "forbidden", details: ["changes": ["label"]]),
                refused(403, "forbidden"),
                refused(403, "type_not_permitted", details: ["changes": ["guidance"]]),
            ] {
                scripted.answer { _ in other }
                let error = await failure { try await server.install(pluginBundle: Self.bytes) }
                #expect(error != nil && error?.pluginInstallRefusal == nil)
            }
        }
    }

    @Test func anAnswerThisBuildCannotReadIsADecodingError() async throws {
        let scripted = ScriptedAuthServer { _ in .json(201, ["name": "reading"], headers: contract) }
        try await withServer(scripted) { server in
            let error = await failure { try await server.install(pluginBundle: Self.bytes) }
            guard case .decoding? = error else {
                Issue.record("\(String(describing: error))")
                return
            }
        }
    }
}
