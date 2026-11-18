import Foundation
import Synchronization
import Testing

@testable import Marfa

extension Server {
    /// A server made from a key, for tests that never reach it.
    static func stub(_ key: String) -> Server {
        Server(url: URL(string: "http://127.0.0.1:1")!, key: key)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct UsingAServer {
    private static func copy(address: String?) -> (WorkingCopy, Counted) {
        let counted = Counted()
        let holder = CoreHolder(
            FakeCore.writer(),
            reopen: { opening in
                counted.add(opening.key)
                return FakeCore.writer()
            }, address: address)
        return (WorkingCopy(holder: holder, hasServer: true), counted)
    }

    @Test func anotherAddressIsRefusedBeforeTheCoreIsReopened() async throws {
        let (copy, counted) = Self.copy(address: "http://127.0.0.1:8080")
        await #expect {
            try await copy.use(Server(url: URL(string: "http://127.0.0.1:8081")!, key: "k"))
        } throws: { error in
            guard case MarfaError.wrongServer(let expected, let got, _) = error else { return false }
            return expected == "http://127.0.0.1:8080" && got == "http://127.0.0.1:8081"
        }
        #expect(counted.keys.isEmpty, "the core was reopened for a server at another address")
        _ = try copy.holder.steadyEpoch()
        await copy.close()
    }

    @Test(arguments: [
        ("http://127.0.0.1:8080", "http://127.0.0.1:8080/"),
        ("https://EXAMPLE.test", "https://example.test"),
        ("https://example.test:443", "https://example.test"),
        ("https://example.test", "https://Example.TEST:443/"),
        ("http://example.test:80/", "http://example.test"),
    ])
    func theSameAddressIsAcceptedHoweverItIsWritten(opened: String, given: String) async throws {
        let (copy, counted) = Self.copy(address: opened)
        try await copy.use(Server(url: URL(string: given)!, key: "k"))
        #expect(counted.keys == ["k"])
        await copy.close()
    }

    @Test(arguments: [
        ("https://example.test", "https://example.test:8443"),
        ("https://example.test", "https://other.test"),
        ("https://example.test", "http://example.test"),
        ("https://example.test", "https://example.test/other"),
        ("https://EXAMPLE.test:443", "https://example.test:444"),
    ])
    func aRealDifferenceIsRefusedHoweverTheAddressIsWritten(opened: String, given: String) async throws {
        let (copy, counted) = Self.copy(address: opened)
        await #expect {
            try await copy.use(Server(url: URL(string: given)!, key: "k"))
        } throws: { error in
            if case MarfaError.wrongServer = error { true } else { false }
        }
        #expect(counted.keys.isEmpty)
        await copy.close()
    }

    @Test func everyCallIsToldToAskAgainFromTheMomentUseBegins() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(
            holder: CoreHolder(core, reopen: { _ in FakeCore.writer() }), hasServer: true)
        let gate = core.holdNextWatch()
        let listening = Task.detached { Heard(copy.changes()) }
        try await eventually("the watch call is held") { core.aWatchWasHeld }
        let changing = Task { try await copy.use(.stub("new-key")) }
        defer { gate.signal() }
        try await eventually("a call is refused while the watch is still shutting down", within: 5) {
            do {
                _ = try await copy.status()
                return false
            } catch let error as Marfa.MarfaError {
                guard case .keyChanging = error else { throw error }
                return true
            }
        }
        gate.signal()
        try await bounded("use") { try await changing.value }
        _ = try await copy.status()
        _ = await listening.value
        await copy.close()
    }
}

final class Counted: Sendable {
    private let seen = Mutex<[String]>([])
    var keys: [String] { seen.withLock { $0 } }
    func add(_ key: String) { seen.withLock { $0.append(key) } }
}
