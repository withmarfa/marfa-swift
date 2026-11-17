import Foundation
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
