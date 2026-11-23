import Foundation
import Synchronization
import Testing

@testable import Marfa
@testable import MarfaAPI

private let contract = ["X-Marfa-Contract": String(marfaContractVersion)]
private let jsonHeaders = contract.merging(["Content-Type": "application/json"]) { $1 }
private let vendor = "app.acme"
private let dataPath = "/app-vendors/\(vendor)/data"

private func removal(removed: Int, types: Int, remaining: Int) -> ScriptedAuthServer.Reply {
    .json(
        200,
        ["vendor": vendor, "removed_items": removed, "removed_types": types, "remaining_items": remaining],
        headers: contract)
}

private let ok: ScriptedAuthServer.Reply = .raw(200, Data(#"{"ok": true}"#.utf8), headers: jsonHeaders)

private func refused(_ status: Int, _ code: String) -> ScriptedAuthServer.Reply {
    .json(status, ["error": ["code": code, "message": "scripted \(code)"]], headers: contract)
}

private func client(_ scripted: ScriptedAuthServer) -> Client {
    Client(
        try! Server(url: scripted.url, key: "marfa_k1_test"), through: scripted.transport().session,
        timeout: .seconds(30))
}

/// Answers each call to the vendor's data with the next reply, and the last reply from then on.
private func pages(_ scripted: ScriptedAuthServer, _ replies: [ScriptedAuthServer.Reply]) {
    let sent = Mutex(0)
    scripted.answer { _ in
        let index = sent.withLock { count in
            defer { count += 1 }
            return count
        }
        return replies[min(index, replies.count - 1)]
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AppDataTests {
    @Test func aRemovalRepeatsUntilTheServerSaysNothingIsLeftAndAddsUpWhatEachCallRemoved() async throws {
        let scripted = ScriptedAuthServer()
        pages(
            scripted,
            [
                removal(removed: 1000, types: 0, remaining: 1500), removal(removed: 1000, types: 0, remaining: 500),
                removal(removed: 500, types: 3, remaining: 0),
            ])
        let result = try await client(scripted).removeAppData(vendor: vendor, .ownerConfirmed, expecting: "inst-1")
        #expect(result.isComplete)
        #expect(result.removedItems == 2500)
        #expect(result.removedTypes == 3)
        #expect(result.remainingItems == 0)
        let sent = scripted.requests(to: dataPath)
        #expect(sent.count == 3)
        #expect(sent.allSatisfy { $0.method == "DELETE" && $0.headers["X-Marfa-Instance-Id"] == "inst-1" })
    }

    @Test func aFailureAfterAPageIsReturnedWithWhatTheServerAnsweredAndIsNotComplete() async throws {
        let scripted = ScriptedAuthServer()
        pages(scripted, [removal(removed: 1000, types: 0, remaining: 200), refused(409, "type_in_use")])
        let result = try await client(scripted).removeAppData(vendor: vendor, .ownerConfirmed)
        #expect(!result.isComplete)
        #expect(result.removedItems == 1000)
        #expect(result.remainingItems == 200)
        guard case .server(409, "type_in_use", _, _, _) = result.stoppedBy else {
            Issue.record("expected type_in_use, got \(String(describing: result.stoppedBy))")
            return
        }
        #expect(scripted.requests(to: dataPath).count == 2)
    }

    @Test func aRefusalOfTheFirstCallIsThrown() async throws {
        let scripted = ScriptedAuthServer()
        pages(scripted, [refused(403, "forbidden")])
        let error = await #expect(throws: MarfaError.self) {
            try await client(scripted).removeAppData(vendor: vendor, .ownerConfirmed)
        }
        #expect(error?.code() == "forbidden")
        #expect(scripted.requests(to: dataPath).count == 1)
    }

    @Test func aServerThatRemovesNothingWhileItemsAreLeftStopsTheLoop() async throws {
        let scripted = ScriptedAuthServer()
        pages(scripted, [removal(removed: 0, types: 0, remaining: 7)])
        let result = try await client(scripted).removeAppData(vendor: vendor, .ownerConfirmed)
        #expect(!result.isComplete)
        #expect(result.remainingItems == 7)
        #expect(result.stoppedBy != nil)
        #expect(scripted.requests(to: dataPath).count == 1)
    }

    @Test func aRemovalOfDataAlreadyGoneIsComplete() async throws {
        let scripted = ScriptedAuthServer()
        pages(scripted, [removal(removed: 0, types: 0, remaining: 0)])
        let result = try await client(scripted).removeAppData(vendor: vendor, .ownerConfirmed)
        #expect(result.isComplete)
        #expect(result.removedItems == 0)
    }

    @Test func theDataListSendsThePageAndReadsEveryState() async throws {
        let scripted = ScriptedAuthServer()
        let page = #"""
            {"vendor": "app.acme", "client_id": "client-1",
             "types": [{"type": "app.acme.note", "active": 1, "archived": 0, "trashed": 1}],
             "data": [{"id": "itm_1", "type": "app.acme.note", "version": 1, "name": "One", "source": "acme",
                       "state": "trashed", "created_at": "2026-11-01T00:00:00.5Z"}],
             "next_cursor": "c2"}
            """#
        scripted.answer { _ in .raw(200, Data(page.utf8), headers: jsonHeaders) }
        let answer = try await client(scripted).appData(vendor: vendor, limit: 10, cursor: "c1")
        #expect(answer.types.first?.trashed == 1)
        #expect(answer.data.first?.state == .trashed)
        #expect(answer.data.first?.createdAt == Date(timeIntervalSince1970: 1_793_491_200.5))
        #expect(answer.nextCursor == .value("c2"))
        let sent = try #require(scripted.requests(to: dataPath).first)
        #expect(sent.method == "GET")
        let query = Set((sent.query ?? "").split(separator: "&").map(String.init))
        #expect(query == ["limit=10", "cursor=c1"])
    }

    @Test(arguments: [false, true])
    func aDisconnectKeepsTheDataUnlessTheOwnerConfirmedRemovingIt(removing: Bool) async throws {
        let scripted = ScriptedAuthServer()
        scripted.answer { _ in ok }
        let api = client(scripted)
        let data: AppDataOnDisconnect = removing ? .remove(.ownerConfirmed) : .keep
        try await api.disconnect(grant: "grt_1", data: data)
        try await api.end(signIn: "sgn_1", data: data)
        let sent = scripted.requests(to: "/grants/grt_1") + scripted.requests(to: "/owner/sign-ins/sgn_1")
        #expect(sent.count == 2)
        for request in sent {
            #expect(request.method == "DELETE")
            #expect((request.query ?? "").contains("remove_data=true") == removing)
            #expect(!(request.query ?? "").contains("revoke_keys"))
        }
    }

    @Test func aDisconnectByDefaultSendsNeitherChoice() async throws {
        let scripted = ScriptedAuthServer()
        scripted.answer { _ in ok }
        try await client(scripted).disconnect(grant: "grt_1")
        try await client(scripted).end(signIn: "sgn_1", revokingKeys: true)
        #expect(scripted.requests(to: "/grants/grt_1").first?.query ?? "" == "")
        #expect(scripted.requests(to: "/owner/sign-ins/sgn_1").first?.query == "revoke_keys=true")
    }

    @Test func grantsAndVendorsReadTheirVendorsAndClientName() async throws {
        let scripted = ScriptedAuthServer()
        let grants = #"""
            {"data": [{"id": "grt_1", "kind": "app", "client_id": "client-1", "client_name": "Acme", "origins": [],
                       "scopes": [], "vendors": ["app.acme"], "status": "active",
                       "granted_at": "2026-11-01T00:00:00Z", "last_used_at": null}], "next_cursor": null}
            """#
        let vendors = #"""
            {"data": [{"vendor": "app.acme", "client_id": "client-1", "client_name": "Acme",
                       "claimed_at": "2026-11-01T00:00:00.822Z"}],
             "next_cursor": null}
            """#
        scripted.answer { request in
            .raw(200, Data((request.path == "/grants" ? grants : vendors).utf8), headers: jsonHeaders)
        }
        let grantList = try await client(scripted).listAppGrants().ok.body.json.data
        #expect(grantList.first?.vendors == [vendor])
        let vendorList = try await client(scripted).listAppVendors().ok.body.json.data
        #expect(vendorList.first?.clientName == .value("Acme"))
        // The server writes milliseconds; a date without them reads too.
        let claimed = try #require(vendorList.first?.claimedAt).timeIntervalSince1970
        #expect(abs(claimed - 1_793_491_200.822) < 0.0005)
    }
}
