import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// Every queued write carries the same `Idempotency-Key` on every attempt.
///
/// **The property is sameness, not presence.** A key that changed per attempt
/// would look identical in a request log and protect nothing — it would tell
/// the server each retry was a new request. So these tests assert that two
/// attempts at one row carry one value, and that two different rows do not
/// share one.
@Suite("Every write carries a key, and a retry carries the same one", .timeLimit(.minutes(1)))
struct IdempotencyKeyTests {

    private func echo(_ id: String) -> ItemResponse {
        let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        return ItemResponse(
            item: Item(
                createdAt: now, id: id, properties: ["body": .string("x")],
                schemaVersion: 1, source: "test", state: .active, tier: .library,
                timestamp: now, type: "core.note", updatedAt: now, version: 1
            ),
            metadata: nil
        )
    }

    /// The POST /items attempts the transport actually saw.
    private func creates(_ transport: MockTransport) -> [MockTransport.Call] {
        transport.calls.filter { $0.path == "/items" && $0.method == .post }
    }

    /// A started engine drains on its own whenever the queue signals, so a
    /// test waits for the attempts it expects rather than calling replay once
    /// and assuming that was the only cycle. Racing an explicit replay against
    /// the proactive one is how the first version of this suite read one
    /// attempt where two had happened.
    /// The discriminator for the whole feature: a replay whose first response
    /// was lost sends the key again, unchanged, so the server can recognize
    /// the write it already performed instead of doing it twice.
    @Test("a retry after a lost response repeats the key rather than minting one")
    func retryRepeatsTheKey() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueueEvents([])
        await engine.start()

        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        let item = try await store.createItem(input)
        try await queue.enqueueCreateItem(input, localId: item.id)

        // A lost response: the write reached the server, the acknowledgement
        // did not. From here that is indistinguishable from never arriving,
        // which is exactly why the key has to survive it.
        transport.enqueueError(NetworkError(URLError(.timedOut)))
        transport.enqueue(echo(item.id))
        await engine.replayMutationsForTesting()
        try await SyncEngineTestKit.awaitCondition(description: "two create attempts") {
            self.creates(transport).count >= 2
        }

        let writes = creates(transport)
        try #require(writes.count == 2)
        let keys = writes.map(\.idempotencyKey)
        #expect(keys.allSatisfy { $0 != nil }, "both attempts must carry a key")
        #expect(keys[0] == keys[1], "a retry is the same request, so it is the same key")
        await engine.stop()
    }

    /// The other half, and the reason the test above is not satisfied by a
    /// constant: two distinct writes must not share a key, or the server would
    /// treat the second as a replay of the first and silently drop it.
    @Test("two different writes carry different keys")
    func distinctWritesGetDistinctKeys() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueueEvents([])
        await engine.start()

        for body in ["one", "two"] {
            let input = CreateItemInput(type: "core.note", properties: ["body": .string(body)])
            let item = try await store.createItem(input)
            try await queue.enqueueCreateItem(input, localId: item.id)
            transport.enqueue(echo(item.id))
        }
        await engine.replayMutationsForTesting()
        try await SyncEngineTestKit.awaitCondition(description: "both creates attempted") {
            self.creates(transport).count >= 2
        }

        let keys = creates(transport).compactMap(\.idempotencyKey)
        try #require(keys.count == 2)
        #expect(Set(keys).count == 2)
        await engine.stop()
    }

    /// The write the key actually protects, and the reason this is not a
    /// create.
    ///
    /// Both create doors already answered a repeat carrying a caller-minted
    /// id, and the kit stamps one. An **unversioned** `PATCH /items/:id` had
    /// nothing: it applies the edit and bumps `version` each time it runs, so
    /// a lost response costs one edit two version steps and leaves the device
    /// behind the server.
    @Test("an unversioned update carries a key, and a retry repeats it")
    func updatesCarryAStableKey() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueueEvents([])
        await engine.start()

        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        let item = try await store.createItem(input)
        try await queue.enqueueUpdateItem(
            id: item.id, properties: ["body": .string("edited")]
        )

        transport.enqueueError(NetworkError(URLError(.timedOut)))
        transport.enqueue(echo(item.id))
        await engine.replayMutationsForTesting()
        try await SyncEngineTestKit.awaitCondition(description: "two patch attempts") {
            transport.calls.filter { $0.method == .patch }.count >= 2
        }

        let patches = transport.calls.filter { $0.method == .patch }
        try #require(patches.count == 2)
        #expect(patches[0].idempotencyKey != nil)
        #expect(patches[0].idempotencyKey == patches[1].idempotencyKey)
        await engine.stop()
    }

    /// A **versioned** update takes the conflict door, and that door is
    /// deliberately unkeyed.
    ///
    /// **This is the case a review found shipping broken, and the fix was to
    /// narrow the claim rather than widen the mechanism.** A key identifies
    /// one request: the server fingerprints method, path, credential and
    /// **body**, and answers a repeat carrying a different body with a `422`
    /// rather than a replay. A `.callback` resolution sends a different body on
    /// every attempt by design — it re-reads the server's copy, hands it to the
    /// resolver and re-sends — so keying it turns a resolution into a refusal,
    /// and the loop gets the unwrapped transport.
    ///
    /// Nothing is lost: the conflict machinery is itself the recovery for the
    /// case a key would have covered — a server that moved under this write.
    /// A row enqueued before keys existed replays **without** one rather than
    /// being given a fresh one. A key invented at replay time differs on every
    /// attempt, which is worse than none: it would tell the server each retry
    /// was a new request while looking, from here, like protection.
    @Test("a row with no key replays without one rather than inventing one")
    func rowWithoutAKeyIsNotGivenOne() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueueEvents([])
        await engine.start()

        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        let item = try await store.createItem(input)
        try await queue.enqueueCreateItem(input, localId: item.id)
        try await queue.clearIdempotencyKeyForTesting(localId: item.id)

        transport.enqueueError(NetworkError(URLError(.timedOut)))
        transport.enqueue(echo(item.id))
        await engine.replayMutationsForTesting()
        try await SyncEngineTestKit.awaitCondition(description: "two create attempts") {
            self.creates(transport).count >= 2
        }

        let writes = creates(transport)
        try #require(writes.count == 2)
        #expect(writes.allSatisfy { $0.idempotencyKey == nil })
        await engine.stop()
    }
}


/// A recorder of its own, rather than `TransportRetryTests`' `StubURLProtocol`.
///
/// That one keys its canned responses and its recorded requests off `static`
/// storage, so two suites using it in parallel take each other's responses —
/// which is exactly what happened, and it reddened the other suite rather than
/// this one. A `.serialized` trait does not help: it orders tests within a
/// suite, not across suites sharing global state.
private final class IdempotencyStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    private static let lock = NSLock()

    nonisolated(unsafe) private static var body: String = "{}"

    /// `body` is what every canned response carries. A conflict-door call
    /// decodes an `ItemResponse`, so `{}` is not always enough.
    static func reset(body: String = "{}") {
        lock.lock(); defer { lock.unlock() }
        recorded = []
        self.body = body
    }

    static func requests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        Self.lock.lock()
        let payload = Self.body
        Self.lock.unlock()
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The header itself, read off a real `URLRequest`.
///
/// **This suite exists because the rest of the file could not have caught the
/// defect it was written to prevent.** `MockTransport` records the
/// `idempotencyKey` *parameter*, so every test above passed against a build
/// where `URLSessionTransport` accepted the argument and never set a header —
/// the feature shipped green and sent nothing. A mock that records what it was
/// handed cannot tell you what went on the wire; only something that builds a
/// request can.
@Suite("The key reaches the wire", .timeLimit(.minutes(1)), .serialized)
struct IdempotencyHeaderTests {

    /// A local factory rather than the one in `TransportRetryTests`, which is
    /// `private` to its file.
    private func stubbedTransport() -> URLSessionTransport {
        URLSessionTransport(
            configuration: ClientConfiguration(
                url: URL(string: "http://test")!, apiKey: "k"
            ),
            protocolClasses: [IdempotencyStubProtocol.self]
        )
    }

    @Test("a keyed request carries the header")
    func keyedRequestSetsTheHeader() async throws {
        IdempotencyStubProtocol.reset()
        let transport = stubbedTransport()

        let _: EmptyResponse = try await transport.request(
            method: .post, path: "/items", body: nil, query: nil,
            idempotencyKey: "key-under-test"
        )

        let sent = try #require(IdempotencyStubProtocol.requests().first)
        #expect(sent.value(forHTTPHeaderField: "Idempotency-Key") == "key-under-test")
    }

    /// The discriminator. Without it the test above passes against a transport
    /// that stamps the header unconditionally from some other value.
    ///
    /// **A read is what makes it a discriminator now.** A write reaching the
    /// unkeyed overload is given a minted key, because that overload is the
    /// direct-mode door and the retry loop behind it would otherwise replay a
    /// write that may already have landed. So the thing that must carry no
    /// header is a request the server would not key anyway.
    @Test("a read carries no header even though a write on the same door is keyed")
    func readSetsNoHeader() async throws {
        IdempotencyStubProtocol.reset()
        let transport = stubbedTransport()

        let _: EmptyResponse = try await transport.request(
            method: .get, path: "/items", body: nil, query: nil
        )
        #expect(try #require(IdempotencyStubProtocol.requests().first)
            .value(forHTTPHeaderField: "Idempotency-Key") == nil)

        let _: EmptyResponse = try await transport.request(
            method: .post, path: "/items", body: nil, query: nil
        )
        #expect(try #require(IdempotencyStubProtocol.requests().last)
            .value(forHTTPHeaderField: "Idempotency-Key") != nil,
            "an unkeyed write door is a duplicate waiting on a timeout")
    }

    /// **Asserted against the wire, not against `MockTransport.Call`.** That
    /// record used to carry no key for a `requestWithConflict` at all, so an
    /// assertion that it was `nil` held whatever the code did and stayed green
    /// through a revert. The door now takes a key, and this reads the header
    /// that actually left.
    @Test("the conflict door forwards the key it is given rather than the row's")
    func conflictDoorForwardsTheCallersKey() async throws {
        IdempotencyStubProtocol.reset()
        let wrapped = KeyedTransport(base: stubbedTransport(), key: "row-key")

        // **The wrapper must not substitute the row's key here.** Only the
        // conflict loop knows which attempt it is on, and only the first
        // attempt can carry a key: a resolver-driven retry re-sends a
        // different body, which a keyed repeat is answered with a `422`. So
        // the wrapper forwards, and passing `nil` has to mean `nil`.
        let _: ConflictResult<EmptyResponse> = try await wrapped.requestWithConflict(
            method: .patch, path: "/items/x", body: nil, query: nil, idempotencyKey: nil
        )
        #expect(try #require(IdempotencyStubProtocol.requests().first)
            .value(forHTTPHeaderField: "Idempotency-Key") == nil)

        // And a key it *is* given reaches the wire — the half that was
        // missing, and the reason a replayed update used to come back as a
        // conflict over the edit its own first attempt landed.
        let _: ConflictResult<EmptyResponse> = try await wrapped.requestWithConflict(
            method: .patch, path: "/items/x", body: nil, query: nil, idempotencyKey: "first-attempt"
        )
        #expect(try #require(IdempotencyStubProtocol.requests().last)
            .value(forHTTPHeaderField: "Idempotency-Key") == "first-attempt")
    }

    /// A key on a read is never right, and the wrapper covers whole replays —
    /// a bulk action posts once and then polls the job with `GET`s through the
    /// same transport.
    @Test("a read through the wrapper carries no key")
    func readsAreNotKeyed() async throws {
        IdempotencyStubProtocol.reset()
        let wrapped = KeyedTransport(base: stubbedTransport(), key: "row-key")

        let _: EmptyResponse = try await wrapped.request(
            method: .get, path: "/items/bulk-actions/jobs/1", body: nil, query: nil
        )
        let sent = try #require(IdempotencyStubProtocol.requests().first)
        #expect(sent.value(forHTTPHeaderField: "Idempotency-Key") == nil)
    }

    /// `X-Request-ID` is the opposite property and shares the code path, so a
    /// change that made one stable would be visible here.
    @Test("the request id still differs per attempt while the key does not")
    func requestIdIsPerAttemptAndTheKeyIsNot() async throws {
        IdempotencyStubProtocol.reset()
        let transport = stubbedTransport()

        for _ in 0..<2 {
            let _: EmptyResponse = try await transport.request(
                method: .post, path: "/items", body: nil, query: nil,
                idempotencyKey: "one-key"
            )
        }

        let sent = IdempotencyStubProtocol.requests()
        try #require(sent.count == 2)
        #expect(sent.map { $0.value(forHTTPHeaderField: "Idempotency-Key") } == ["one-key", "one-key"])
        let requestIds = sent.compactMap { $0.value(forHTTPHeaderField: "X-Request-ID") }
        #expect(Set(requestIds).count == 2)
    }

    /// The negative control for the path the header first landed on by
    /// mistake. Reading confirms `rawUpload` sets no key; this suite exists
    /// because reading is what failed last time.
    @Test("an upload carries no key")
    func uploadsCarryNoHeader() async throws {
        IdempotencyStubProtocol.reset()
        let transport = stubbedTransport()

        _ = try await transport.rawUpload(
            method: .post, path: "/blobs", body: Data("bytes".utf8),
            contentType: "application/octet-stream", query: nil, onBytesSent: { _, _ in }
        )

        let sent = try #require(IdempotencyStubProtocol.requests().first)
        #expect(sent.value(forHTTPHeaderField: "Idempotency-Key") == nil)
    }
}
