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

private func refused(_ status: Int, _ code: String) -> ScriptedAuthServer.Reply {
    .json(status, ["error": ["code": code, "message": "scripted \(code)"]], headers: contract)
}

/// A server signed in to `scripted` with the access token `at-1`, whose requests never leave the process.
private func signedIn(_ scripted: ScriptedAuthServer, _ keychain: Keychain) throws -> Server {
    let authorization = try Authorization(
        server: scripted.url, client: .init(name: "Server calls tests", scopes: ["core.note:read"]),
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

private let versions = """
    {"data": [
      {"id": "v2", "item_id": "i1", "version": 2, "properties": {"title": "Second", "count": 3, "done": true},
       "type": "core.note", "tier": "feed", "occurred_at": "2026-10-27", "source_id": null,
       "writer": {"kind": "app", "id": "g1", "name": "MAPP"}, "created_at": "2026-10-27T14:00:00.000Z"},
      {"id": "v1", "item_id": "i1", "version": 1, "properties": {"title": "First"},
       "type": "core.note", "tier": "library", "occurred_at": "2026-10-27T09:30:00Z", "source_id": "s",
       "created_at": "2026-10-26T14:00:00.000Z"}
    ], "next_cursor": "c2"}
    """

@Suite(.timeLimit(.minutes(1)))
struct ServerCallsTests {
    @Test func snapshotsReadOnePageWithTheCursorAndLimitSent() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in reply(versions) }
            let server = try signedIn(scripted, keychain)
            let page = try await server.snapshots(ofItem: "i1", after: "c1", limit: 2)
            let request = try #require(scripted.requests(to: "/items/i1/versions").first)
            #expect(request.method == "GET")
            #expect(request.query == "limit=2&cursor=c1")
            #expect(request.headers["Authorization"] == "Bearer at-1")
            #expect(page.next == "c2")
            #expect(page.snapshots.map(\.version) == [2, 1])
            let first = try #require(page.snapshots.first)
            #expect(first.properties["title"] == .string("Second"))
            #expect(first.properties["count"] == .integer(3))
            #expect(first.tier == .feed && page.snapshots[1].tier == .library)
            #expect(first.writer == .init(kind: .app, id: "g1", name: "MAPP"))
            #expect(page.snapshots[1].writer == nil)
            #expect(first.occurredAt?.hasTime == false)
            #expect(page.snapshots[1].occurredAt?.hasTime == true)
            #expect(first.createdAt.timeIntervalSince1970 == 1_793_109_600)
        }
    }

    @Test func theCursorAndLimitAreSentAsQueryItems() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in reply(#"{"data": [], "next_cursor": null}"#) }
            let server = try signedIn(scripted, keychain)
            let page = try await server.snapshots(ofItem: "a/b", after: "c 1&x=2+y/z", limit: 5)
            #expect(page.snapshots.isEmpty && page.next == nil)
            let request = try #require(scripted.requests.first)
            #expect(request.path == "/items/a%2Fb/versions", "an identifier is one path segment")
            #expect(request.query?.contains("+") == false, "a server reads + in a query as a space")
            let sent = URLComponents(string: "?" + (request.query ?? ""))?.queryItems ?? []
            #expect(
                sent == [URLQueryItem(name: "limit", value: "5"), URLQueryItem(name: "cursor", value: "c 1&x=2+y/z")])
        }
    }

    @Test func aSnapshotOfAnUnknownWriterKindKeepsTheKindItWasGiven() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in
                reply(
                    """
                    {"data": [{"id": "v1", "item_id": "i1", "version": 1, "properties": {}, "type": "core.note",
                     "tier": "library", "occurred_at": "2026-10-27", "source_id": null,
                     "writer": {"kind": "robot", "id": "r1", "name": "Robot"},
                     "created_at": "2026-10-27T14:00:00.000Z"}], "next_cursor": null}
                    """)
            }
            let page = try await signedIn(scripted, keychain).snapshots(ofItem: "i1")
            let writer = try #require(page.snapshots.first?.writer, "a writer of an unknown kind is still a writer")
            #expect(writer.kind == .other("robot") && writer.kind.rawValue == "robot")
            #expect(writer.id == "r1" && writer.name == "Robot")
        }
    }

    @Test func aSnapshotWithATimeThisBuildCannotReadFailsThePage() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in
                reply(versions.replacingOccurrences(of: "2026-10-26T14:00:00.000Z", with: "yesterday"))
            }
            let error = await failure { try await signedIn(scripted, keychain).snapshots(ofItem: "i1") }
            #expect(error?.code() == "decoding", "\(String(describing: error))")
        }
    }

    @Test func writerKindsReadAsTheServerNamesThem() {
        for kind in [ItemSnapshot.Writer.Kind.browser, .app, .key, .local, .other("robot")] {
            #expect(ItemSnapshot.Writer.Kind(rawValue: kind.rawValue) == kind)
        }
    }

    @Test func appsCanBuildTheValuesForPreviews() {
        let snapshot = ItemSnapshot(
            id: "v1", itemID: "i1", version: 1, type: "core.note", tier: .library, properties: ["title": "A"],
            occurredAt: nil, sourceID: nil, writer: .init(kind: .app, id: "g1", name: "MAPP"),
            createdAt: Date(timeIntervalSince1970: 0))
        let page = ItemSnapshotPage(snapshots: [snapshot], next: nil)
        #expect(page.snapshots == [snapshot])
        let config = InstanceConfig(instanceID: "inst", name: "Home", inboundPendingRetentionDays: 7)
        #expect(config.name == "Home" && config.inboundPendingRetentionDays == 7 && config.trashRetentionDays == nil)
    }

    @Test func aServerMadeFromAKeySendsTheKeyOverItsOwnConnection() async throws {
        let local = try await LocalServer.start(contract: marfaContractVersion)
        defer { local.stop() }
        let page = try await Server(url: local.url, key: "mk_plain").snapshots(ofItem: "a/b", after: "c1", limit: 3)
        #expect(page.snapshots.isEmpty && page.next == nil)
        let head = try #require(local.log.all.first)
        #expect(head.hasPrefix("GET /items/a%2Fb/versions?limit=3&cursor=c1 HTTP/1.1\r\n"), "\(head)")
        #expect(head.lowercased().contains("authorization: bearer mk_plain\r\n"), "\(head)")
    }

    @Test func aServerMadeFromAKeyIsNeverRenewed() async throws {
        let local = try await LocalServer.start(contract: marfaContractVersion) { _, _ in
            (401, "application/json", #"{"error": {"code": "unauthorized", "message": "no"}}"#)
        }
        defer { local.stop() }
        let error = await failure { try await Server(url: local.url, key: "mk_plain").config() }
        #expect(error?.code() == "unauthorized", "\(String(describing: error))")
        #expect(local.log.all.count == 1)
    }

    @Test func aServerThatNeverAnswersThrowsOnceTheTimeoutPasses() async throws {
        let local = try await LocalServer.start(contract: marfaContractVersion, holdsResponse: true)
        defer { local.stop() }
        let started = ContinuousClock.now
        let error = await failure {
            try await Server(url: local.url, key: "mk_plain").config(timeout: .milliseconds(500))
        }
        #expect(error?.code() == "network", "\(String(describing: error))")
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func theTimeoutCoversRenewingTheTokenAndSendingAgain() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let renewal = Hold()
            defer { renewal.release() }
            let scripted = ScriptedAuthServer { request in
                request.path == "/auth/oauth2/token"
                    ? .held(
                        renewal, .json(200, ["access_token": "at-2", "refresh_token": "rt-2", "token_type": "Bearer"]))
                    : refused(401, "unauthorized")
            }
            let server = try signedIn(scripted, keychain)
            let started = ContinuousClock.now
            let error = await failure { try await server.config(timeout: .seconds(1)) }
            #expect(error?.code() == "network", "\(String(describing: error))")
            #expect(ContinuousClock.now - started < .seconds(10), "a renewal that never ends does not hold the call")
        }
    }

    @Test func aRefusalArrivesAsAMarfaError() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in refused(404, "item_not_found") }
            let server = try signedIn(scripted, keychain)
            let error = await failure { try await server.snapshots(ofItem: "gone") }
            guard case .notFound(let code, _)? = error else {
                Issue.record("expected notFound, got \(String(describing: error))")
                return
            }
            #expect(code == "item_not_found")
        }
    }

    @Test func aServerNamingNoContractIsRefused() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in .raw(200, Data("{}".utf8), headers: [:]) }
            let server = try signedIn(scripted, keychain)
            let error = await failure { try await server.config() }
            #expect(error?.code() == "contract_mismatch", "\(String(describing: error))")
        }
    }

    @Test func aRefusedAccessTokenIsRenewedOnceAndTheCallSentAgain() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer()
            scripted.answer { request in
                switch (request.path, request.headers["Authorization"]) {
                case ("/auth/oauth2/token", _):
                    .json(200, ["access_token": "at-2", "refresh_token": "rt-2", "token_type": "Bearer"])
                case (_, "Bearer at-2"): reply(#"{"instance_id": "x"}"#)
                default: refused(401, "unauthorized")
                }
            }
            let server = try signedIn(scripted, keychain)
            let config = try await server.config()
            #expect(config.instanceID == "x")
            #expect(
                scripted.requests(to: "/config").map { $0.headers["Authorization"] } == ["Bearer at-1", "Bearer at-2"])
        }
    }

    @Test func aRedirectIsNeverFollowed() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in
                .raw(302, Data(), headers: ["Location": "https://elsewhere.example/config"])
            }
            let server = try signedIn(scripted, keychain)
            let error = await failure { try await server.config() }
            #expect(error?.code() == "redirect", "\(String(describing: error))")
            #expect(scripted.requests.count == 1)
        }
    }

    @Test func anOfflineDeviceThrowsNoConnection() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in .failure(.notConnectedToInternet) }
            let server = try signedIn(scripted, keychain)
            let error = await failure { try await server.config() }
            #expect(error?.code() == "no_connection", "\(String(describing: error))")
        }
    }

    @Test func configReadsEverySettingTheServerNames() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in
                reply(
                    """
                    {"instance_id": "inst", "name": "Home", "trash_retention_days": 30, "version_recent_days": 7,
                     "version_daily_snapshot_days": 30, "version_weekly_snapshot_days": 90, "version_max_versions": 50,
                     "enrichment_enabled": true, "inbound_handled_retention_days": 14,
                     "inbound_pending_retention_days": 0, "enforcement": {"strict_mode": {"types": ["a"]}}}
                    """)
            }
            let config = try await signedIn(scripted, keychain).config()
            #expect(config.instanceID == "inst" && config.name == "Home")
            #expect(config.trashRetentionDays == 30 && config.versionRecentDays == 7)
            #expect(config.versionDailySnapshotDays == 30 && config.versionWeeklySnapshotDays == 90)
            #expect(config.versionMaxVersions == 50 && config.enrichmentEnabled == true)
            #expect(config.inboundHandledRetentionDays == 14 && config.inboundPendingRetentionDays == 0)
            #expect(config.heartbeatEnabled == nil && config.grantInactivityDays == nil)
        }
    }

    @Test func updateConfigSendsOnlyTheChangedFieldsAndTheInstanceHeader() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in reply(#"{"instance_id": "inst", "name": "Renamed"}"#) }
            let server = try signedIn(scripted, keychain)
            var patch = InstanceConfigPatch()
            patch.name = .set("Renamed")
            patch.versionMaxVersions = .clear
            patch.enrichmentEnabled = .set(false)
            patch.inboundHandledRetentionDays = .set(30)
            patch.inboundPendingRetentionDays = .clear
            let stored = try await server.updateConfig(patch, expecting: "inst")
            #expect(stored.name == "Renamed")
            let request = try #require(scripted.requests(to: "/config").first)
            #expect(request.method == "PATCH")
            #expect(request.headers["X-Marfa-Instance-Id"] == "inst")
            #expect(request.headers["Content-Type"] == "application/json")
            let body = request.json
            #expect(
                Set(body.keys) == [
                    "name", "version_max_versions", "enrichment_enabled", "inbound_handled_retention_days",
                    "inbound_pending_retention_days",
                ])
            #expect(body["inbound_handled_retention_days"] as? Int == 30)
            #expect(body["inbound_pending_retention_days"] is NSNull)
            #expect(body["name"] as? String == "Renamed")
            #expect(body["version_max_versions"] is NSNull)
            #expect(body["enrichment_enabled"] as? Bool == false)
        }
    }

    @Test func updateConfigWithoutAnInstanceSendsNoHeader() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in reply(#"{"instance_id": "inst"}"#) }
            let server = try signedIn(scripted, keychain)
            _ = try await server.updateConfig(InstanceConfigPatch())
            let request = try #require(scripted.requests(to: "/config").first)
            #expect(request.headers["X-Marfa-Instance-Id"] == nil)
            #expect(request.json.isEmpty)
        }
    }

    @Test func anotherInstanceIsRefusedWhereItLands() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in refused(409, "instance_changed") }
            let server = try signedIn(scripted, keychain)
            var patch = InstanceConfigPatch()
            patch.name = .clear
            let error = await failure { try await server.updateConfig(patch, expecting: "old") }
            guard case .instanceChanged? = error else {
                Issue.record("expected instance_changed, got \(String(describing: error))")
                return
            }
        }
    }

    @Test func aTypeIconIsSetAndClearedAndTheAnswerIsTheIconNow() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { request in
                request.method == "PUT"
                    ? reply(#"{"type": {"id": "t", "display_hints": {"icon": "lucide:book-open"}}}"#)
                    : reply(#"{"type": {"id": "t"}}"#)
            }
            let server = try signedIn(scripted, keychain)
            let set = try await server.setTypeIcon("lucide:book-open", ofType: "app.x.t", expecting: "inst")
            #expect(set == "lucide:book-open")
            let put = try #require(scripted.requests.first)
            #expect(put.method == "PUT" && put.path == "/types/app.x.t/icon")
            #expect(put.json["icon"] as? String == "lucide:book-open")
            #expect(put.headers["X-Marfa-Instance-Id"] == "inst")
            let cleared = try await server.setTypeIcon(nil, ofType: "app.x.t")
            #expect(cleared == nil)
            #expect(scripted.requests.last?.method == "DELETE")
        }
    }

    @Test func anIconTheServerRefusesIsAValidationError() async throws {
        try await inIsolatedKeychainAsync { keychain, _ async throws in
            let scripted = ScriptedAuthServer { _ in refused(400, "invalid_schema") }
            let server = try signedIn(scripted, keychain)
            let error = await failure { try await server.setTypeIcon("book-open", ofType: "t") }
            guard case .validation("invalid_schema", _)? = error else {
                Issue.record("expected validation, got \(String(describing: error))")
                return
            }
        }
    }
}
