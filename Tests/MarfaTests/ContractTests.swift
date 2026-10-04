import Foundation
import MarfaTypes
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct ContractTests {
    @Test func aServerOnTheNextContractIsRefusedNamingTheOneTheTypesDescribe() async throws {
        let server = try await LocalServer.start(contract: marfaContractVersion + 1)
        defer { server.stop() }
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: Server(url: server.url, key: "k"))
        do {
            _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
            Issue.record("a server on contract \(marfaContractVersion + 1) was not refused")
        } catch let MarfaError.contractMismatch(served, expected, status, writeSent, _) {
            #expect(served == String(marfaContractVersion + 1))
            #expect(expected == UInt64(marfaContractVersion))
            #expect(status == 200)
            #expect(!writeSent)
        }
        await copy.close()
    }

    @Test(arguments: ["/next", nil] as [String?])
    func aRedirectPreservesItsResponseWithoutFollowingIt(location: String?) async throws {
        let server = try await LocalServer.start(
            contract: marfaContractVersion,
            headers: location.map { "location: \($0)\r\n" } ?? ""
        ) { _, _ in (307, "application/json", "{}") }
        defer { server.stop() }
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: Server(url: server.url, key: "k"))
        do {
            _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
            Issue.record("a redirect was accepted")
        } catch let MarfaError.redirected(origin, status, destination, message) {
            #expect(origin == server.url.absoluteString)
            #expect(status == 307)
            #expect(destination == location)
            #expect(!message.isEmpty)
            #expect(server.log.all.count == 1)
        }
        await copy.close()
    }

    @Test func aServerOnTheContractTheTypesDescribeIsReadPastTheCheck() async throws {
        let server = try await LocalServer.start(contract: marfaContractVersion, answer: Waiting.hydrating)
        defer { server.stop() }
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: Server(url: server.url, key: "k"))
        let report = try await copy.hydrate(types: ["core.note"], tier: .feed)
        #expect(report.types == ["core.note"])
        #expect(report.cursor == "10")
        await copy.close()
    }
}
