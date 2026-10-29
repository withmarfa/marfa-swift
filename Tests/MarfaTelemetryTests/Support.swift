import Foundation
import Network
import Synchronization
import Testing

@testable import MarfaTelemetry

/// Keeps every request instead of sending it.
///
/// With `holdingFirst`, the first send does not return until `release()`.
final class Recorder: TelemetryTransport {
    private let seen = Mutex<[TelemetryRequest]>([])
    private let gate: AsyncStream<Void>
    private let opening: AsyncStream<Void>.Continuation
    private let holdingFirst: Bool

    init(holdingFirst: Bool = false) {
        (gate, opening) = AsyncStream<Void>.makeStream()
        self.holdingFirst = holdingFirst
    }

    var requests: [TelemetryRequest] { seen.withLock { $0 } }

    func release() { opening.yield() }

    func send(_ request: TelemetryRequest) async {
        let first = seen.withLock { requests in
            requests.append(request)
            return requests.count == 1
        }
        if holdingFirst, first {
            for await _ in gate { break }
        }
    }
}

func destination(_ host: String = "https://eu.i.posthog.com") throws -> Telemetry.Destination {
    try Telemetry.Destination(host: URL(string: host)!, projectToken: "phc_test")
}

/// A clock the test moves.
final class TestClock: Sendable {
    private let start = ContinuousClock.Instant.now
    private let elapsed = Mutex<Duration>(.zero)

    var now: ContinuousClock.Instant { start.advanced(by: elapsed.withLock { $0 }) }

    func advance(_ duration: Duration) { elapsed.withLock { $0 += duration } }
}

func configured(
    _ recorder: Recorder, interval: Duration = .seconds(30), enabled: Bool = true, clock: TestClock = TestClock()
) throws -> Telemetry {
    let telemetry = Telemetry(transport: recorder, interval: interval, now: { clock.now })
    telemetry.configure(
        .init(destination: try destination(), serviceName: "mapp", serviceVersion: "1.2.3"))
    telemetry.isEnabled = enabled
    return telemetry
}

func object(_ request: TelemetryRequest) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
}

/// The log records of a request, in order.
func records(_ request: TelemetryRequest) throws -> [[String: Any]] {
    let resourceLogs = try #require(try object(request)["resourceLogs"] as? [[String: Any]])
    let scopeLogs = try #require(resourceLogs.first?["scopeLogs"] as? [[String: Any]])
    return try #require(scopeLogs.first?["logRecords"] as? [[String: Any]])
}

func eventually(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(20)
    while !condition() {
        guard Date.now < deadline else {
            Issue.record("never: \(what)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// A server on a loopback port that answers every request with `response` and counts the connections it gets.
final class LoopbackServer: Sendable {
    private let listener: NWListener
    private final class Tally: Sendable {
        let value = Mutex(0)
    }

    private let count = Tally()

    var connections: Int { count.value.withLock { $0 } }
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(response: @escaping @Sendable () -> String) async throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [count] connection in
            count.value.withLock { $0 += 1 }
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let reply = response()
                connection.send(
                    content: Data(reply.utf8), contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = AsyncStream<Void>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.continuation.yield() }
        }
        listener.start(queue: .global())
        for await _ in ready.stream { break }
    }

    deinit { listener.cancel() }
}
