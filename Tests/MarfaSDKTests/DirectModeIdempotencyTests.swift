import Testing
import Foundation
@testable import MarfaSDK

/// Per-suite URLProtocol stub — see `Transport401RefreshTests` for the
/// rationale on scoped subclasses. This one records every request it sees,
/// because the point of these tests is what the *second* attempt carried.
final class DirectModeStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var script: [(Int, Data)?] = []
    nonisolated(unsafe) private static var seen: [(method: String, key: String?)] = []

    /// A `nil` entry fails that attempt with a timeout, which is the shape
    /// this is about: the server may well have committed the write and only
    /// the response was lost.
    static func script(_ entries: [(Int, Data)?]) {
        lock.lock(); defer { lock.unlock() }
        script = entries
        seen = []
    }

    static var requests: [(method: String, key: String?)] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.seen.append((
            request.httpMethod ?? "?",
            request.value(forHTTPHeaderField: "Idempotency-Key")
        ))
        let entry = Self.script.isEmpty ? nil : Self.script.removeFirst()
        Self.lock.unlock()

        guard let (status, body) = entry else {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeDirectClient() -> MarfaClient {
    let config = ClientConfiguration(
        url: URL(string: "http://test")!,
        apiKey: "k",
        retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0, jitter: 0)
    )
    return MarfaClient(
        configuration: config,
        transport: URLSessionTransport(
            configuration: config, protocolClasses: [DirectModeStubURLProtocol.self]
        )
    )
}

/// **A client with no local store still retries, and a retry is a replay.**
/// The transport retries `.timedOut` and `.networkConnectionLost` on any
/// method, and the reason recorded for that is that the request cannot have
/// completed — which is exactly what a timeout does not tell you. The server
/// may have committed the write and lost only the response.
@Suite("Direct-mode idempotency", .serialized)
struct DirectModeIdempotencyTests {

    /// Encoded from a real `Item` rather than hand-written, so a fixture that
    /// drifts from the wire shape fails the encoder here instead of surfacing
    /// as a decode error inside the assertion and reading like the defect.
    private var itemBody: Data {
        let item = Item(
            createdAt: "2026-04-19T12:00:00Z",
            id: "i1",
            properties: [:],
            schemaVersion: 1,
            source: "test",
            state: .active, tier: .feed,
            timestamp: "2026-04-19T12:00:00Z",
            type: "core.note",
            updatedAt: "2026-04-19T12:00:00Z",
            version: 1
        )
        return try! JSONEncoder().encode(ItemResponse(item: item))
    }

    /// The discriminator is that **both** attempts carry the **same** key. A
    /// key minted per attempt would be worse than none: it would tell the
    /// server each retry was a new request while looking, from here, like
    /// protection.
    @Test("a create retried after a timeout repeats its key rather than making a second item")
    func createRepeatsItsKeyAcrossARetry() async throws {
        DirectModeStubURLProtocol.script([nil, (201, itemBody)])
        let client = makeDirectClient()

        _ = try await client.items.create(CreateItemInput(type: "core.note", properties: [:]))

        let sent = DirectModeStubURLProtocol.requests
        #expect(sent.count == 2, "the timeout should have been retried")
        let keys = sent.map(\.key)
        #expect(keys.allSatisfy { $0 != nil }, "a retried write with no key creates a second item")
        #expect(keys[0] == keys[1], "a key minted per attempt is worse than none")
    }

    /// A versioned update carries the same exposure with a worse symptom: the
    /// first attempt moves the version, so the unkeyed retry is refused as a
    /// conflict over the edit that landed, and the caller is told it collided
    /// when it succeeded.
    @Test("a versioned update retried after a timeout repeats its key")
    func versionedUpdateRepeatsItsKeyAcrossARetry() async throws {
        DirectModeStubURLProtocol.script([nil, (200, itemBody)])
        let client = makeDirectClient()

        _ = try await client.items.update(id: "i1", properties: [:], options: UpdateOptions(version: 1))

        let sent = DirectModeStubURLProtocol.requests
        #expect(sent.count == 2)
        let keys = sent.map(\.key)
        #expect(keys.allSatisfy { $0 != nil })
        #expect(keys[0] == keys[1])
    }

    /// **Two separate calls must not share a key**, or the second is answered
    /// with the first's response and the write is silently dropped. This is
    /// the failure a per-client or per-path key would introduce while every
    /// assertion above still passed.
    @Test("two separate creates carry different keys")
    func separateCallsDoNotShareAKey() async throws {
        DirectModeStubURLProtocol.script([(201, itemBody), (201, itemBody)])
        let client = makeDirectClient()

        _ = try await client.items.create(CreateItemInput(type: "core.note", properties: [:]))
        _ = try await client.items.create(CreateItemInput(type: "core.note", properties: [:]))

        let keys = DirectModeStubURLProtocol.requests.map(\.key)
        #expect(keys.count == 2)
        #expect(keys[0] != keys[1], "a shared key makes the second write a replay of the first")
    }

    /// A read carries no key. The server keys only writes, and stamping a
    /// header on every request would put a meaningless one on every list.
    @Test("a read carries no key")
    func readsAreNotKeyed() async throws {
        DirectModeStubURLProtocol.script([(200, itemBody)])
        let client = makeDirectClient()

        _ = try await client.items.get(id: "i1")

        #expect(DirectModeStubURLProtocol.requests.first?.key == nil)
    }
}
