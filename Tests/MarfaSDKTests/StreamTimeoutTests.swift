import Testing
import Foundation
@testable import MarfaSDK

/// URLProtocol stub that writes a canned body in timed pieces and, when
/// asked, stops writing without ever finishing the response.
///
/// The silent tail is why this exists rather than reusing the SSE stub: a
/// stream that has gone quiet but is still open is the one case only an
/// inactivity timeout can end, and a stub that always finishes cleanly can
/// never produce it. The static configuration is its own, so this suite
/// cannot race another that installs a different stub.
final class StreamTimeoutStubURLProtocol: URLProtocol, @unchecked Sendable {

    struct Config: Sendable {
        var statusCode: Int = 200
        /// Written to the client in order, the first immediately and each
        /// later one `chunkInterval` after its predecessor.
        var chunks: [Data] = []
        var chunkInterval: TimeInterval = 0
        /// When true the response is never finished after the last chunk,
        /// so the request ends only if something times it out.
        var holdOpenAfterLastChunk: Bool = false
    }

    nonisolated(unsafe) private static var storedConfig = Config()
    private static let configLock = NSLock()
    private static let queue = DispatchQueue(label: "marfa.tests.stream-timeout-stub")

    static func configure(_ config: Config) {
        configLock.withLock { storedConfig = config }
    }

    private static var currentConfig: Config {
        configLock.withLock { storedConfig }
    }

    private let stateLock = NSLock()
    private var stopped = false
    private var isLive: Bool { stateLock.withLock { !stopped } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let config = Self.currentConfig
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: config.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        emit(config.chunks[...], every: config.chunkInterval, holdOpen: config.holdOpenAfterLastChunk)
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
    }

    /// Emits one chunk per hop rather than scheduling them all up front, so
    /// a cancelled request stops writing and the held-open case parks with
    /// nothing scheduled instead of a thread asleep on a deadline.
    private func emit(_ chunks: ArraySlice<Data>, every interval: TimeInterval, holdOpen: Bool) {
        guard let chunk = chunks.first else {
            if !holdOpen { client?.urlProtocolDidFinishLoading(self) }
            return
        }
        client?.urlProtocol(self, didLoad: chunk)
        let rest = chunks.dropFirst()
        if rest.isEmpty, holdOpen { return }
        Self.queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, self.isLive else { return }
            self.emit(rest, every: interval, holdOpen: holdOpen)
        }
    }
}

/// The heartbeat interval the server sends SSE comments on, and the constant
/// the shipped `streamTimeout` default is derived from. Restated here because
/// a Swift package cannot import a TypeScript constant, so the relationship
/// between the two is only as true as something that checks it.
private let documentedServerHeartbeat: TimeInterval = 30

/// The ordinary resource timeout used by the two tests that are about it,
/// shrunk from the shipped default so they measure the relationship between
/// the timeouts rather than waiting out the real ones.
private let ordinaryResourceTimeout: TimeInterval = 1.0

/// Long enough that whichever timeout a test is not about cannot be what
/// ended anything in it.
private let generousTimeout: TimeInterval = 30.0

/// Each test sets both bounds explicitly, because which of the two ended a
/// request is the entire question here and a shared default would let one
/// test pass on the other's timeout.
private func makeConfiguration(
    resourceTimeout: TimeInterval,
    streamTimeout: TimeInterval
) -> ClientConfiguration {
    ClientConfiguration(
        url: URL(string: "http://test")!,
        apiKey: "k",
        timeoutInterval: generousTimeout,
        resourceTimeout: resourceTimeout,
        streamTimeout: streamTimeout,
        // One attempt: these tests are about how long a call is allowed to
        // run, and a retry would multiply every wait below by the budget.
        retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0, jitter: 0)
    )
}

private func makeTransport(
    resourceTimeout: TimeInterval,
    streamTimeout: TimeInterval
) -> URLSessionTransport {
    let configuration = makeConfiguration(
        resourceTimeout: resourceTimeout, streamTimeout: streamTimeout
    )
    return URLSessionTransport(
        configuration: configuration, protocolClasses: [StreamTimeoutStubURLProtocol.self]
    )
}

/// How a stream ended, reduced to something `Sendable` and comparable: a
/// task group cannot carry an `Error` across, and the assertion only needs to
/// tell a timeout apart from every other way a stream can finish.
private enum StreamOutcome: Sendable, Equatable, CustomStringConvertible {
    case timedOut
    case endedWithOtherError(String)
    case finishedCleanly
    case stillOpen

    init(endedWith error: any Error) {
        // The transport rethrows a stream failure as it found it, so a
        // timeout arrives as a bare `URLError`; the wrapped shape is checked
        // too so this cannot pass or fail on which layer happened to catch it.
        let urlError = (error as? URLError) ?? ((error as? NetworkError)?.underlyingError as? URLError)
        self = urlError?.code == .timedOut ? .timedOut : .endedWithOtherError(String(describing: error))
    }

    var description: String {
        switch self {
        case .timedOut: "a timeout"
        case .endedWithOtherError(let error): "a different error: \(error)"
        case .finishedCleanly: "a clean finish, with no timeout"
        case .stillOpen: "a stream still open at the deadline"
        }
    }
}

@Suite("Stream and request timeouts", .serialized)
struct StreamTimeoutTests {

    @Test("the default stream timeout outlasts the server's heartbeat")
    func defaultStreamTimeoutOutlastsTheHeartbeat() {
        let configuration = ClientConfiguration(
            url: URL(string: "http://test")!, apiKey: "k"
        )

        // The floor. A default at or below the heartbeat interval ends a
        // stream that is being fed normally, the first time a ping is a
        // fraction late — which is the two-minute reconnect loop this change
        // removes, returning under a different cause and a shorter period.
        #expect(
            configuration.streamTimeout > documentedServerHeartbeat,
            """
            the default stream timeout must outlast the \
            \(documentedServerHeartbeat)s server heartbeat
            """
        )

        // The published derivation. The changelog, the property's own doc
        // comment and the Swift docs page all say "twice the server's
        // heartbeat", and a claim in three places that nothing checks is a
        // claim that drifts. Asserted as the relationship rather than as 60,
        // so the number can move as long as the reasoning still holds.
        #expect(
            configuration.streamTimeout >= documentedServerHeartbeat * 2,
            """
            the documented derivation is twice the \
            \(documentedServerHeartbeat)s heartbeat, so a whole missed ping \
            is tolerated
            """
        )
    }

    @Test("a stream is still delivering past the ordinary resource timeout")
    func streamOutlivesTheResourceTimeout() async throws {
        // Five events, one every half the ordinary resource timeout, so the
        // last is due at twice that timeout. Nothing else configured here is
        // short enough to end the stream, so a short count means the
        // resource timeout ended it.
        let eventCount = 5
        let interval = ordinaryResourceTimeout / 2
        StreamTimeoutStubURLProtocol.configure(.init(
            chunks: (1...eventCount).map { Data("data: e\($0)\n\n".utf8) },
            chunkInterval: interval
        ))
        let transport = makeTransport(
            resourceTimeout: ordinaryResourceTimeout, streamTimeout: generousTimeout
        )

        var received: [SSEEvent] = []
        var streamError: (any Error)?
        do {
            for try await event in transport.eventStream(
                path: "/events", query: nil, lastEventID: nil
            ) {
                received.append(event)
            }
        } catch {
            streamError = error
        }

        #expect(
            streamError == nil,
            """
            the stream ended before \(interval * Double(eventCount - 1))s, \
            twice the \(ordinaryResourceTimeout)s resource timeout: \
            \(String(describing: streamError))
            """
        )
        #expect(received.map(\.data) == (1...eventCount).map { "e\($0)" })
    }

    @Test("an ordinary request still gives up at the resource timeout")
    func ordinaryRequestKeepsItsResourceTimeout() async throws {
        // A guard rather than a red-first assertion: this holds before the
        // stream split and after it. Lifting the resource bound off the
        // stream is one line away from lifting it off every request, and
        // that would be silent — nothing else here notices a client that
        // waits indefinitely on a body the server never finishes.
        let interval = ordinaryResourceTimeout / 2
        StreamTimeoutStubURLProtocol.configure(.init(
            chunks: (1...5).map { Data("chunk\($0)".utf8) },
            chunkInterval: interval
        ))
        let transport = makeTransport(
            resourceTimeout: ordinaryResourceTimeout, streamTimeout: generousTimeout
        )

        var caught: (any Error)?
        do {
            _ = try await transport.rawRequest(
                method: .get, path: "/items", body: nil, contentType: nil, query: nil
            )
        } catch {
            caught = error
        }

        let network = caught as? NetworkError
        #expect(network != nil, "expected a NetworkError, got \(String(describing: caught))")
        #expect((network?.underlyingError as? URLError)?.code == .timedOut)
    }

    @Test("a stream that goes silent ends on the inactivity timeout")
    func silentStreamEndsOnTheInactivityTimeout() async throws {
        // One event, then nothing, ever.
        //
        // Both of the other bounds are set far beyond the deadline below, and
        // that is what makes the assertion mean anything: a stream ending
        // inside the deadline can only have been ended by its own inactivity
        // timeout, because neither the request timeout nor the resource
        // timeout has come close to expiring. Without that separation this
        // test passes on the resource timeout — which is the very thing the
        // change removes from the stream — and so would have passed before
        // the fix and after it.
        let streamTimeout = 0.5
        let resourceTimeout = generousTimeout / 4
        StreamTimeoutStubURLProtocol.configure(.init(
            chunks: [Data("data: only\n\n".utf8)],
            chunkInterval: 0,
            holdOpenAfterLastChunk: true
        ))
        let transport = makeTransport(
            resourceTimeout: resourceTimeout, streamTimeout: streamTimeout
        )

        // Three times the inactivity timeout, so a stream still open at the
        // deadline is not merely late — and a small fraction of the
        // resource timeout, so that bound cannot be what ended it.
        let deadline = streamTimeout * 3
        let outcome = await withTaskGroup(
            of: StreamOutcome.self, returning: StreamOutcome.self
        ) { group in
            group.addTask {
                do {
                    for try await _ in transport.eventStream(
                        path: "/events", query: nil, lastEventID: nil
                    ) {}
                    return .finishedCleanly
                } catch {
                    return .init(endedWith: error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(deadline))
                return .stillOpen
            }
            let first = await group.next() ?? .stillOpen
            group.cancelAll()
            return first
        }

        // Not merely "the stream ended". A cancellation, a parse failure or a
        // clean finish would all end it too, and none of them is the timeout
        // firing — so the assertion names the error the way the ordinary
        // request's guard above does.
        #expect(
            outcome == .timedOut,
            """
            expected the stream to time out within \(deadline)s of its last \
            byte — three times the \(streamTimeout)s inactivity timeout, and \
            well inside the \(resourceTimeout)s resource timeout, which is \
            therefore not what should end it. Got \(outcome).
            """
        )
    }
}
