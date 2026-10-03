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
    }

    /// The empty page names no event cursor, so `noCursor` shows the
    /// contract check passed.
    @Test func aServerOnTheContractTheTypesDescribeIsReadPastTheCheck() async throws {
        let server = try await LocalServer.start(contract: marfaContractVersion)
        defer { server.stop() }
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: Server(url: server.url, key: "k"))
        do {
            _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
            Issue.record("an empty page hydrated")
        } catch MarfaError.noCursor {}
    }
}
