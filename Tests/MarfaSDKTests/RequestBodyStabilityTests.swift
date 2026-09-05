import Testing
import Foundation
@testable import MarfaSDK

/// Captures what actually left, body and key, and answers a 409 so a
/// conflict-aware call completes.
///
/// **Only covers bodies sent on the request.** `rawUpload` hands its body to
/// the task rather than the request, so a protocol sees it in neither
/// property — pointing this at a blob upload would capture `""` and pass.
///
/// **Reads `httpBodyStream` as well as `httpBody`**, because `URLSession`
/// converts a body to a stream on its way through and the plain property is
/// nil by the time a protocol sees it. A capture that only read `httpBody`
/// would compare two empty strings and pass whatever the kit sent.
private final class RequestBodyCaptureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [(body: String, key: String?)] = []

    static func reset() { lock.lock(); seen = []; lock.unlock() }
    static var requests: [(body: String, key: String?)] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            // `hasBytesAvailable` is only reliable in the affirmative, so
            // the read's own result ends the loop rather than the property.
            while true {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            data = collected
        }
        Self.lock.lock()
        Self.seen.append((
            String(data: data ?? Data(), encoding: .utf8) ?? "<unreadable>",
            request.value(forHTTPHeaderField: "Idempotency-Key")
        ))
        Self.lock.unlock()

        let body = Data(#"""
        {"error":{"code":"version_conflict","status":409,"message":"stale"},
         "current":{"version":2,"properties":{}},
         "ancestor":{"version":1,"properties":{}},
         "conflicting_fields":["title"],
         "merge_policy":{"default":"last_writer_wins"}}
        """#.utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 409, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// **An idempotency key names a body, so the body has to be stable.**
///
/// The server fingerprints method, path, credential and body, and refuses a
/// key replayed with a *different* request. Swift's synthesized `Codable`
/// fills a keyed container backed by a dictionary, so encoding one value twice
/// could emit its keys in different orders — and two orderings of the same
/// content are two different requests as far as the fingerprint is concerned.
///
/// **Unfixed, a key made things worse rather than better.** A replay after a
/// lost response used to conflict, which the conflict machinery could settle.
/// Refused as `idempotency_key_reused` it cannot succeed at all.
///
/// Found by a live scenario that sent one body twice under one key and was
/// told the key had been used for a different request — the server was right
/// and the bytes really had changed.
@Suite("Request body stability", .serialized)
struct RequestBodyStabilityTests {

    private func makeTransport() -> URLSessionTransport {
        let config = ClientConfiguration(
            url: URL(string: "http://test")!,
            apiKey: "k",
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0, jitter: 0)
        )
        return URLSessionTransport(
            configuration: config, protocolClasses: [RequestBodyCaptureProtocol.self]
        )
    }

    /// The conflict door, which is the one that carries a key across a retry.
    @Test("one body sent twice under one key produces identical bytes")
    func repeatedSendsAreByteIdentical() async throws {
        RequestBodyCaptureProtocol.reset()
        let transport = makeTransport()
        let body = UpdateItemBody(
            properties: ["title": .string("stable"), "notes": .string("also stable")],
            version: 1
        )
        let key = UUIDv7.generateString()

        for _ in 0..<2 {
            let _: ConflictResult<ItemResponse> = try await transport.requestWithConflict(
                method: .patch, path: "/items/x", body: body, query: nil, idempotencyKey: key
            )
        }

        let sent = RequestBodyCaptureProtocol.requests
        try #require(sent.count == 2)
        #expect(sent[0].key == sent[1].key, "the same key must reach both sends")
        #expect(
            sent[0].body == sent[1].body,
            "the same value encoded to different bytes: \(sent.map(\.body))"
        )
    }

    /// **The ordinary write door too.** It mints its own key per call, so a
    /// caller never sees a repeat — but the transport's own retry of one call
    /// does, and that is the window the key exists to cover.
    @Test("the plain request door encodes stably as well")
    func plainRequestsAreByteIdentical() async throws {
        RequestBodyCaptureProtocol.reset()
        let transport = makeTransport()
        let body = UpdateItemBody(
            properties: ["title": .string("stable"), "notes": .string("also stable")],
            version: 1
        )

        for _ in 0..<2 {
            _ = try? await transport.request(
                method: .patch, path: "/items/x", body: body, query: nil
            ) as ItemResponse
        }

        let sent = RequestBodyCaptureProtocol.requests
        try #require(sent.count == 2)
        #expect(sent[0].body == sent[1].body, "\(sent.map(\.body))")
        // Two separate calls, so two separate keys — sharing one would make
        // the second write a replay of the first and drop it.
        #expect(sent[0].key != sent[1].key)
    }

    /// **The strongest of the three, and none of them is certain.** Measured
    /// with the fix reverted over ten runs: this reddened eight times, and the
    /// two above once and twice. Swift varies its keyed-container ordering per
    /// encoding, not per process, so every one of these is a sampling of that
    /// variation rather than a proof.
    ///
    /// Two things make this one the guard rather than merely the luckiest.
    /// **Ten keys instead of two**, so a spuriously sorted permutation is one
    /// in ten factorial rather than one in two. And **`tier` before
    /// `version`**, which sorted order produces and the declaration order
    /// (`properties, version, tier`) does not — asserting `properties` before
    /// `version` would have held for both and distinguished nothing.
    @Test("keys are emitted in sorted order")
    func keysAreSorted() async throws {
        RequestBodyCaptureProtocol.reset()
        let transport = makeTransport()
        let names = ["zebra", "yak", "walrus", "tapir", "quail",
                     "newt", "marmot", "lynx", "koala", "alpaca"]
        var properties: [String: JSONValue] = [:]
        for name in names { properties[name] = .string(name) }

        let _: ConflictResult<ItemResponse> = try await transport.requestWithConflict(
            method: .patch, path: "/items/x", body: UpdateItemBody(
                properties: properties, version: 1, tier: .library
            ),
            query: nil, idempotencyKey: "k"
        )

        let sent = try #require(RequestBodyCaptureProtocol.requests.first).body

        // `tier` before `version` is the discriminator: sorted order gives it,
        // declaration order does not.
        let tier = try #require(sent.range(of: "\"tier\""))
        let version = try #require(sent.range(of: "\"version\""))
        #expect(tier.lowerBound < version.lowerBound, "top-level keys are not sorted: \(sent)")

        // And the ten property keys, in order, so a partial sort is caught.
        let positions = try names.sorted().map { name in
            try #require(sent.range(of: "\"\(name)\"")).lowerBound
        }
        #expect(positions == positions.sorted(), "property keys are not sorted: \(sent)")
    }
}
