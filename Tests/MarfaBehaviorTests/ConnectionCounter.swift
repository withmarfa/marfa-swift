#if DEBUG
import Foundation
import Network
import Synchronization

/// A listener on a loopback port that counts the connections it accepts and answers none of them.
final class ConnectionCounter: Sendable {
    private let listener: NWListener
    private final class Tally: Sendable {
        let value = Mutex(0)
    }

    private let count = Tally()

    var connections: Int { count.value.withLock { $0 } }
    let url: URL

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [count] connection in
            count.value.withLock { $0 += 1 }
            connection.start(queue: .global())
            connection.cancel()
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
        self.listener = listener
        guard let url = URL(string: "http://127.0.0.1:\(port)") else { throw URLError(.badURL) }
        self.url = url
    }

    deinit { listener.cancel() }
}
#endif
