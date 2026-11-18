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

    @Test func theSameAddressIsAcceptedWhateverItsTrailingSlash() async throws {
        let (copy, counted) = Self.copy(address: "http://127.0.0.1:8080")
        try await copy.use(Server(url: URL(string: "http://127.0.0.1:8080/")!, key: "k"))
        #expect(counted.keys == ["k"])
        await copy.close()
    }
}

final class Counted: Sendable {
    private let seen = Mutex<[String]>([])
    var keys: [String] { seen.withLock { $0 } }
    func add(_ key: String) { seen.withLock { $0.append(key) } }
}
