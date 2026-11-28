import Foundation
import Testing

@testable import Marfa
@testable import MarfaAPI

private let contract = ["X-Marfa-Contract": String(marfaContractVersion)]

private func conflict(_ details: [String: any Sendable]) -> ScriptedAuthServer.Reply {
    let error: [String: any Sendable] = [
        "code": "version_conflict", "message": "changed since you read it", "details": details,
    ]
    return .json(409, ["error": error], headers: contract)
}

private let storedType: [String: any Sendable] = [
    "id": "app.test.entry", "label": "Entry", "fields": [String: String](), "version": 1, "revision": "rev-2",
    "plural": "Entries", "provenance": ["origin": "registered"] as [String: String],
]

private func client(_ scripted: ScriptedAuthServer) -> Client {
    Client(
        try! Server(url: scripted.url, key: "marfa_k1_test"), through: scripted.transport().session,
        timeout: .seconds(30))
}

private func refusal(_ call: () async throws -> some Any) async -> MarfaError? {
    do {
        _ = try await call()
        return nil
    } catch {
        return error as? MarfaError
    }
}

@Suite(.timeLimit(.minutes(1)))
struct StaleWriteTests {
    @Test func aStaleWebhookChangeIsAVersionConflictThatNamesTheCurrentVersion() async {
        let scripted = ScriptedAuthServer { _ in conflict(["version": 7]) }

        let error = await refusal {
            try await client(scripted).updateWebhook(
                path: .init(id: "wh-1"), body: .json(.init(active: false, version: 3)))
        }

        guard case .versionConflict? = error else {
            Issue.record("\(String(describing: error))")
            return
        }
        #expect(error?.currentVersion == 7)
        #expect(error?.currentRevision == nil)
        #expect(scripted.requests.first?.json["version"] as? Int == 3)
    }

    @Test func aStaleTypeReplaceIsAVersionConflictThatNamesTheCurrentRevision() async {
        let scripted = ScriptedAuthServer { _ in conflict(["revision": "rev-9"]) }

        let error = await refusal {
            try await client(scripted).replace(
                itemType: "app.test.entry", with: .init(fields: .init(), revision: "rev-1"))
        }

        guard case .versionConflict? = error else {
            Issue.record("\(String(describing: error))")
            return
        }
        #expect(error?.currentRevision == "rev-9")
        #expect(error?.currentVersion == nil)
    }

    @Test func aStaleTypeDeleteIsAVersionConflictThatNamesTheCurrentRevision() async {
        let scripted = ScriptedAuthServer { _ in conflict(["revision": "rev-9"]) }

        let error = await refusal { try await client(scripted).delete(itemType: "app.test.entry", revision: "rev-1") }

        guard case .versionConflict? = error else {
            Issue.record("\(String(describing: error))")
            return
        }
        #expect(error?.currentRevision == "rev-9")
    }

    @Test func aReplaceSendsTheRevisionOfTheDefinitionAndNoneWhenTheDefinitionHasNone() async throws {
        let scripted = ScriptedAuthServer { _ in .json(200, storedType, headers: contract) }
        let api = client(scripted)

        _ = try await api.replace(itemType: "app.test.entry", with: .init(fields: .init(), revision: "rev-1"))
        _ = try await api.replace(itemType: "app.test.entry", with: .init(fields: .init()))

        let bodies = scripted.requests(to: "/types/app.test.entry").map(\.json)
        #expect(bodies.count == 2)
        #expect(bodies.first?["revision"] as? String == "rev-1")
        #expect(bodies.last?["revision"] == nil)
    }

    @Test func aDeleteSendsTheRevisionAsAQueryItemAndNoneWhenNil() async throws {
        let scripted = ScriptedAuthServer { _ in .json(200, ["ok": true], headers: contract) }
        let api = client(scripted)

        try await api.delete(itemType: "app.test.entry", revision: "rev 1/2")
        try await api.delete(itemType: "app.test.entry", force: true, revision: nil)

        let sent = scripted.requests(to: "/types/app.test.entry")
        #expect(sent.count == 2)
        #expect(sent.first?.method == "DELETE")
        let first = URLComponents(string: "?" + (sent.first?.query ?? ""))?.queryItems ?? []
        #expect(first.contains(URLQueryItem(name: "revision", value: "rev 1/2")))
        let second = URLComponents(string: "?" + (sent.last?.query ?? ""))?.queryItems ?? []
        #expect(second.contains { $0.name == "revision" } == false)
        #expect(second.contains(URLQueryItem(name: "force", value: "true")))
    }

    @Test func aConflictWithNoCurrentValueReadsAsNone() {
        let bare = MarfaError.versionConflict(message: "m", server: nil)
        let wrong = MarfaError.versionConflict(
            message: "m",
            server: ServerAnswer(
                status: 409, code: "version_conflict",
                details: .object(JSONObject(members: [JSONMember(key: "version", value: .string("7"))])),
                requestId: nil))
        let other = MarfaError.notFound(
            code: "not_found", message: "m",
            server: ServerAnswer(
                status: 404, code: "not_found",
                details: .object(JSONObject(members: [JSONMember(key: "version", value: .integer(7))])),
                requestId: nil))

        #expect(bare.currentVersion == nil && bare.currentRevision == nil)
        #expect(wrong.currentVersion == nil)
        #expect(other.currentVersion == nil)
    }
}
