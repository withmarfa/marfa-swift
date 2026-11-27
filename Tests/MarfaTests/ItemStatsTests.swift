import Foundation
import MarfaTesting
import MarfaTypes
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct ItemStatsTests {
    private static let contract = ["X-Marfa-Contract": String(marfaContractVersion)]

    @Test func countsByTypeWithListingFilters() async throws {
        let scripted = ScriptedAuthServer { _ in
            .raw(200, Data(#"{"core.note":9007199254740993,"core.task":2}"#.utf8), headers: Self.contract)
        }
        let filter = #"backref[parent-of] exists AND properties.title eq "A+B?&C""#
        let id = "01912345-6789-7000-8000-0123456789ab"
        let filters = ItemStatsFilters(
            types: ["core.task", "core.note"], states: [.active, .archived], tier: .library, tags: ["work", "a&b"],
            occurredAfter: "2026-11-01", occurredBefore: "2026-11-30", source: "oauth:notes",
            updatedAfter: "2026-11-01T12:00:00+01:00", updatedBefore: "2026-11-27T12:00:00Z", filter: filter,
            beneath: id, includeHidden: true)
        let counts = try await Self.server(scripted).itemStats(by: .type, filters: filters)
        #expect(counts == ["core.note": 9_007_199_254_740_993, "core.task": 2])

        let request = try #require(scripted.requests(to: "/items/stats").first)
        #expect(request.method == "GET")
        #expect(request.headers["Authorization"] == "Bearer at-1")
        #expect(request.headers["X-Marfa-Contract"] == String(marfaContractVersion))
        var components = URLComponents()
        components.percentEncodedQuery = request.query
        let query = try #require(components.queryItems)
        #expect(
            Set(query) == [
                .init(name: "by", value: "type"), .init(name: "type", value: "core.note,core.task"),
                .init(name: "state", value: "active,archived"), .init(name: "tier", value: "library"),
                .init(name: "tags", value: "work,a&b"), .init(name: "source", value: "oauth:notes"),
                .init(name: "occurred_after", value: "2026-11-01"), .init(name: "occurred_before", value: "2026-11-30"),
                .init(name: "updated_after", value: "2026-11-01T12:00:00+01:00"),
                .init(name: "updated_before", value: "2026-11-27T12:00:00Z"), .init(name: "filter", value: filter),
                .init(name: "beneath", value: id), .init(name: "include", value: "hidden"),
            ])
        #expect(query.count == 13)
        #expect(scripted.requests.count == 1)
    }

    @Test func countsBySource() async throws {
        let scripted = ScriptedAuthServer { _ in .json(200, ["oauth:notes": 4, "cli": 1], headers: Self.contract) }
        let counts = try await Self.server(scripted).itemStats(by: .source)
        #expect(counts == ["oauth:notes": 4, "cli": 1])
        #expect(scripted.requests(to: "/items/stats").first?.query == "by=source")
    }

    @Test func defaultsToCountsByStateAcrossAllStates() async throws {
        let scripted = ScriptedAuthServer { _ in .json(200, ["active": 4, "trashed": 1], headers: Self.contract) }
        let counts = try await Self.server(scripted).itemStats()
        #expect(counts == ["active": 4, "trashed": 1])
        #expect(scripted.requests(to: "/items/stats").first?.query == "by=state")
    }

    @Test func returnsAnEmptyDictionaryForAnEmptyResult() async throws {
        let scripted = ScriptedAuthServer { _ in .json(200, [:], headers: Self.contract) }
        let counts = try await Self.server(scripted).itemStats(by: .type)
        #expect(counts.isEmpty)
        #expect(scripted.requests(to: "/items/stats").count == 1)
    }

    @Test func preservesATypePermissionRefusal() async throws {
        let scripted = ScriptedAuthServer { _ in
            .json(
                403, ["error": ["code": "type_not_permitted", "message": "This credential reaches no type."]],
                headers: Self.contract)
        }
        let server = try Self.server(scripted, scopes: [], refreshToken: "rt-1")
        let error = await #expect(throws: MarfaError.self) { try await server.itemStats() }
        guard case .forbidden(let code, _, _)? = error else {
            Issue.record("expected forbidden, got \(String(describing: error))")
            return
        }
        #expect(code == "type_not_permitted")
        #expect(scripted.requests.map(\.path) == ["/items/stats"])
    }

    @Test func renewsARefusedTokenAndRepeatsTheSameQueryOnce() async throws {
        let scripted = ScriptedAuthServer { request in
            switch (request.path, request.headers["Authorization"]) {
            case ("/oauth/token", _):
                .json(200, ["access_token": "at-2", "refresh_token": "rt-2", "token_type": "Bearer"])
            case ("/items/stats", "Bearer at-2"):
                .json(200, ["oauth:notes": 4], headers: Self.contract)
            default:
                .json(
                    401, ["error": ["code": "unauthorized", "message": "The access token expired."]],
                    headers: Self.contract)
            }
        }
        let server = try Self.server(scripted, refreshToken: "rt-1")
        let counts = try await server.itemStats(by: .source, filters: .init(updatedAfter: "2026-11-01"))
        #expect(counts == ["oauth:notes": 4])
        #expect(scripted.requests.map(\.path) == ["/items/stats", "/oauth/token", "/items/stats"])
        let reads = scripted.requests(to: "/items/stats")
        #expect(reads.map { $0.headers["Authorization"] } == ["Bearer at-1", "Bearer at-2"])
        #expect(reads.map(\.query) == Array(repeating: "by=source&updated_after=2026-11-01", count: 2))
        #expect(scripted.requests(to: "/oauth/token").first?.form["refresh_token"] == "rt-1")
    }

    private static func server(
        _ scripted: ScriptedAuthServer, scopes: [String] = ["core.note:read"], refreshToken: String? = nil
    ) throws -> Server {
        let credential = try Credential.keeping(
            accessToken: "at-1", refreshToken: refreshToken, scopes: scopes, server: scripted.url,
            keychain: MemoryKeychain().keychain, service: "com.withmarfa.marfa-swift.tests",
            session: scripted.transport().session)
        return try Server(url: scripted.url, credential: credential)
    }
}
