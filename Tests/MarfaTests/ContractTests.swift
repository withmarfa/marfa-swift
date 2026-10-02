import Foundation
import MarfaTypes
import Network
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct ContractTests {
    @Test func aServerOnTheNextContractIsRefusedNamingTheOneTheTypesDescribe() async throws {
        let server = try await ContractServer.start(contract: marfaContractVersion + 1)
        defer { server.stop() }
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: Server(url: server.url, key: "k"))
        do {
            _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
            Issue.record("a server on contract \(marfaContractVersion + 1) was not refused")
        } catch let MarfaError.contractMismatch(served, expected, _, _, _) {
            #expect(served == String(marfaContractVersion + 1))
            #expect(expected == UInt64(marfaContractVersion))
        }
    }

    /// The empty page names no event cursor, so `noCursor` shows the
    /// contract check passed.
    @Test func aServerOnTheContractTheTypesDescribeIsReadPastTheCheck() async throws {
        let server = try await ContractServer.start(contract: marfaContractVersion)
        defer { server.stop() }
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: Server(url: server.url, key: "k"))
        do {
            _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
            Issue.record("an empty page hydrated")
        } catch MarfaError.noCursor {}
    }
}

private struct ContractServer: Sendable {
    let url: URL
    let listener: NWListener

    static func start(contract: Int) async throws -> ContractServer {
        let body = #"{"data":[],"next_cursor":null}"#
        let answer = Data(
            ("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nx-marfa-contract: \(contract)\r\n"
                + "content-length: \(body.utf8.count)\r\nconnection: close\r\n\r\n\(body)").utf8)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { _, _, _, _ in
                connection.send(content: answer, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        let url = try #require(URL(string: "http://127.0.0.1:\(port)"))
        return ContractServer(url: url, listener: listener)
    }

    func stop() {
        listener.cancel()
    }
}
