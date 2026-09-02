import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

// Shared fixtures and helpers for the split SyncEngine test files. Namespaced
// under an enum to avoid colliding with same-named private helpers in
// unrelated suites.
enum SyncEngineTestKit {

    // Pair-builder: shared `ModelContainer` so the queue and store
    // commit to the same SQLite file (synced-mode shape).
    static func makeStoreAndQueue() async throws -> (LocalStore, MutationQueue) {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        return (store, queue)
    }

    /// Stamps the store as one that has already completed a full import.
    ///
    /// The engine imports when it comes online and this timestamp is absent,
    /// so a store without it fetches the item and edge pages before opening
    /// the stream — which lands in the middle of whatever response sequence a
    /// test queued. Most suites here are about a device that has been running
    /// for a while, and this is what that device's store looks like.
    static func markImported(_ queue: MutationQueue) async throws {
        let stamp = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        try await queue.saveSyncState(key: "last_full_sync_at", value: stamp)
    }

    // Build a full synced client fixture.
    //
    // `hasImportedBefore` defaults to the device that has already imported,
    // because that is the shape nearly every suite in this file is about. Pass
    // `false` for the cold-start shape, where coming online pulls the library.
    static func makeFixture(hasImportedBefore: Bool = true) async throws -> (
        store: LocalStore,
        queue: MutationQueue,
        transport: MockTransport,
        connManager: ConnectionStateManager,
        engine: SyncEngine
    ) {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        if hasImportedBefore { try await markImported(queue) }
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        return (store, queue, transport, connManager, engine)
    }

    /// Fixture variant for the proactive-drain tests — short debounce so
    /// assertions don't need to sleep for the 150 ms default.
    static func makeFixtureWithShortDebounce(
        hasImportedBefore: Bool = true
    ) async throws -> (
        store: LocalStore,
        queue: MutationQueue,
        transport: MockTransport,
        connManager: ConnectionStateManager,
        engine: SyncEngine
    ) {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        if hasImportedBefore { try await markImported(queue) }
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager,
            drainDebounceInterval: .milliseconds(20)
        )
        return (store, queue, transport, connManager, engine)
    }

    /// Everything the engine published to `stream`, read back after `stop()`
    /// has finished it.
    ///
    /// Stopping first is what makes this finite: the buffer is unbounded, so
    /// every event emitted beforehand is still delivered, and the finish is
    /// what ends the iteration. Reading a live stream instead would block for
    /// the whole suite budget in exactly the case worth naming, where the
    /// engine published nothing, and report a time limit rather than the
    /// absence itself.
    static func publishedEvents(
        from stream: AsyncStream<SyncEvent>,
        closing engine: SyncEngine
    ) async -> [SyncEvent] {
        await engine.stop()
        var collected: [SyncEvent] = []
        for await event in stream { collected.append(event) }
        return collected
    }

    /// Thrown by `waitUntil` when `condition` never becomes true before the
    /// timeout, so the failure names what was awaited and for how long
    /// instead of leaving the caller's next line — and the assertion after
    /// it — to run against state the wait never established.
    struct WaitUntilTimeoutError: Error, CustomStringConvertible {
        let description: String
    }

    // Simple polling helper — SSE consumption is task-driven and can't be
    // pinned to a known deadline. Poll until `condition` returns true or
    // the timeout elapses, then throw. Keeps its own deadline instead of
    // leaning on Swift Testing's `.timeLimit` trait: that trait's
    // granularity bottoms out at a minute, far coarser than these
    // sub-second waits.
    static func waitUntil(
        timeout: Duration,
        every: Duration = .milliseconds(10),
        description: String,
        _ condition: @Sendable () async throws -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if try await condition() { return }
            try await Task.sleep(for: every)
        }
        if try await condition() { return }
        throw WaitUntilTimeoutError(
            description: "timed out after \(timeout) waiting for \(description)"
        )
    }

    /// The inverse of ``waitUntil``: proves something does *not* happen while
    /// the window is open. Used for lifecycle invariants a regression breaks
    /// immediately — a missing wait or guard publishes state within a couple
    /// of actor hops, so a window measured in hundreds of milliseconds is
    /// decisive rather than a timing gamble.
    ///
    /// Unlike `waitUntil`, this isn't a readiness gate a caller builds on:
    /// every call site here runs unconditional teardown afterward (signaling
    /// a lock, stopping an engine, releasing a blocked transport), never an
    /// assertion that assumes the window held. `Issue.record` already names
    /// the right failure when the condition fires early, and throwing would
    /// skip that teardown and leak the blocked task or lock into the next
    /// test instead.
    static func expectRemainsFalse(
        for duration: Duration,
        every: Duration = .milliseconds(10),
        _ condition: @Sendable () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            if try await condition() {
                // Not a throw: every call site runs unconditional teardown right
                // after this returns, so throwing here would skip it and leak
                // whatever that teardown was releasing (a lock, an engine, a
                // blocked transport) into the next test.
                Issue.record("expectRemainsFalse: condition became true within \(duration)")
                return
            }
            try await Task.sleep(for: every)
        }
    }
}

/// One-shot flag for observing that an async consumer finished.
actor TestLatch {
    private(set) var isSet = false

    func set() {
        isSet = true
    }
}

// Test-only Transport used by the concurrency-guard test. Its `request` call
// suspends on a continuation until the test calls `release(...)`, simulating
// a real network round-trip and forcing actor reentry. The `eventStream`
// side mirrors MockTransport's minimal semantics.
actor BlockingTransport: Transport {
    private var eventStreams: [[SSEEvent]] = []
    private var continuation: CheckedContinuation<Data, Never>?
    private(set) var itemsCallCount = 0

    func enqueueEvents(_ events: [SSEEvent]) {
        eventStreams.append(events)
    }

    func release<T: Encodable>(result: T) {
        let data = try! JSONEncoder().encode(result)
        continuation?.resume(returning: data)
        continuation = nil
    }

    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T {
        if path == "/items" && method == .get {
            itemsCallCount += 1
            let data: Data = await withCheckedContinuation { cont in
                self.continuation = cont
            }
            return try JSONDecoder().decode(T.self, from: data)
        }
        if path == "/edges" && method == .get {
            // The initial sync's second pass. This transport exists to hold the
            // *items* request open, so edges answer straight away with an empty
            // page: a second continuation would make the one this class offers
            // ambiguous, and no test here is about the edge pass.
            let empty = PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false)
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(empty))
        }
        fatalError("BlockingTransport: unexpected request \(method.rawValue) \(path)")
    }

    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> ConflictResult<T> {
        fatalError("BlockingTransport: requestWithConflict not supported")
    }

    func rawRequest(
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?,
        query: [(String, String)]?
    ) async throws -> (Data, HTTPURLResponse) {
        fatalError("BlockingTransport: rawRequest not supported")
    }

    nonisolated func eventStream(
        path: String,
        query: [(String, String)]?,
        lastEventID: String?
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let events = await self.popEventStream()
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    private func popEventStream() -> [SSEEvent] {
        guard !eventStreams.isEmpty else { return [] }
        return eventStreams.removeFirst()
    }
}

// Cancellation-resistant replay transport used to prove `SyncEngine.stop()`
// waits for an already-started mutation attempt to finish accounting.
actor BlockingReplayTransport: Transport {
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var requestStarted = false
    private var requestStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocking = true
    private(set) var requestCallCount = 0

    func waitUntilRequestStarted() async {
        if requestStarted { return }
        await withCheckedContinuation { continuation in
            requestStartedWaiters.append(continuation)
        }
    }

    func releaseRequest() {
        requestContinuation?.resume()
        requestContinuation = nil
    }

    /// Releases the in-flight request and lets every later one fail straight
    /// through. Teardown after a restart cannot know whether the engine has
    /// already reopened a replay, so a one-shot release would race it.
    func stopBlocking() {
        blocking = false
        releaseRequest()
    }

    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T {
        requestCallCount += 1
        requestStarted = true
        for waiter in requestStartedWaiters { waiter.resume() }
        requestStartedWaiters.removeAll()
        if blocking {
            await withCheckedContinuation { continuation in
                requestContinuation = continuation
            }
        }
        throw NetworkError(
            NSError(
                domain: "stop-barrier-test",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "released failure"]
            )
        )
    }

    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> ConflictResult<T> {
        fatalError("BlockingReplayTransport: requestWithConflict not supported")
    }

    func rawRequest(
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?,
        query: [(String, String)]?
    ) async throws -> (Data, HTTPURLResponse) {
        fatalError("BlockingReplayTransport: rawRequest not supported")
    }

    nonisolated func eventStream(
        path: String,
        query: [(String, String)]?,
        lastEventID: String?
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

// A cancellation-resistant successful replay. The first mutation waits until
// the test releases it, letting stop() flip the engine lifecycle before the
// replay loop reaches the next queued record.
actor BlockingSuccessfulReplayTransport: Transport {
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var requestStarted = false
    private var requestStartedWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilRequestStarted() async {
        if requestStarted { return }
        await withCheckedContinuation { continuation in
            requestStartedWaiters.append(continuation)
        }
    }

    func releaseRequest() {
        requestContinuation?.resume()
        requestContinuation = nil
    }

    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T {
        requestStarted = true
        for waiter in requestStartedWaiters { waiter.resume() }
        requestStartedWaiters.removeAll()
        await withCheckedContinuation { continuation in
            requestContinuation = continuation
        }
        let data = try JSONEncoder().encode(EmptyResponse())
        return try JSONDecoder().decode(T.self, from: data)
    }

    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> ConflictResult<T> {
        fatalError("BlockingSuccessfulReplayTransport: requestWithConflict not supported")
    }

    func rawRequest(
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?,
        query: [(String, String)]?
    ) async throws -> (Data, HTTPURLResponse) {
        fatalError("BlockingSuccessfulReplayTransport: rawRequest not supported")
    }

    nonisolated func eventStream(
        path: String,
        query: [(String, String)]?,
        lastEventID: String?
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

/// A transport whose event stream stays open until the test closes it.
///
/// `MockTransport` finishes every stream the instant it is created, and that
/// difference is why this whole class of defect was invisible from a unit
/// test: everything the engine does after the stream closes — the queue
/// drain above all — ran immediately, so a write that only a stream close
/// would have replayed looked replayed. A live server holds the stream open
/// for the session, and on that server nothing behind the close ever runs.
///
/// Responses and errors are a single FIFO each, matching `MockTransport`, so
/// a test enqueues them in the order the engine will ask.
actor HeldOpenStreamTransport: Transport {

    private var responses: [Data] = []
    private var errors: [Error?] = []
    private var recordedCalls: [MockTransport.Call] = []
    private var streamContinuations: [AsyncThrowingStream<SSEEvent, Error>.Continuation] = []
    private(set) var openStreamCount = 0
    private(set) var openStreamsFinished = false
    private var held: (method: HTTPMethod, path: String)?
    private var heldContinuation: CheckedContinuation<Void, Never>?
    private(set) var heldRequestReached = false
    private var concurrencyGuard: (method: HTTPMethod, path: String)?
    private var inFlightGuarded = 0

    struct NoResponseQueued: Error, CustomStringConvertible {
        let method: String
        let path: String
        var description: String {
            "HeldOpenStreamTransport: no response queued for \(method) \(path)"
        }
    }

    var calls: [MockTransport.Call] { recordedCalls }

    // MARK: - Configuration

    func enqueue<T: Encodable>(_ response: T) throws {
        responses.append(try JSONEncoder().encode(response))
    }

    func enqueueError(_ error: Error) {
        errors.append(error)
    }

    /// Suspends the next `method` request to `path` until
    /// ``releaseHeldRequest()``. The engine's coming-online phase is
    /// microseconds wide against a mock and seconds wide against a real
    /// library, and this is what lets a test stand inside it.
    ///
    /// Matched on the verb as well as the path, because `/items` is both the
    /// import's page fetch and a queued create's replay, and holding the wrong
    /// one silently tests something else.
    func holdNextRequest(method: HTTPMethod, path: String) {
        held = (method, path)
    }

    /// Records an issue if a second `method` request to `path` is ever in
    /// flight while the first still is. Cheaper than a window a test has to
    /// wait out, and it fails for the right reason: two imports running at
    /// once rather than two arriving eventually.
    func failOnConcurrentRequest(method: HTTPMethod, path: String) {
        concurrencyGuard = (method, path)
    }

    func releaseHeldRequest() {
        heldContinuation?.resume()
        heldContinuation = nil
    }

    func yieldEvent(_ event: SSEEvent) {
        for continuation in streamContinuations { continuation.yield(event) }
    }

    /// Closes every open stream, which is what a server-side idle timeout
    /// looks like to the engine.
    func finishOpenStreams() {
        for continuation in streamContinuations { continuation.finish() }
        streamContinuations.removeAll()
        openStreamsFinished = true
    }

    // MARK: - Transport

    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T {
        let bodyData = body.flatMap { try? JSONEncoder().encode(AnyEncodable($0)) }
        recordedCalls.append(
            MockTransport.Call(method: method, path: path, body: bodyData, query: query)
        )
        let guarded = concurrencyGuard.map { $0.method == method && $0.path == path } ?? false
        if guarded {
            inFlightGuarded += 1
            if inFlightGuarded > 1 {
                Issue.record(
                    "a second \(method.rawValue) \(path) ran while one was still in flight"
                )
            }
        }
        defer { if guarded { inFlightGuarded -= 1 } }

        if let held, held.method == method, held.path == path {
            self.held = nil
            heldRequestReached = true
            // Cancellable, because a real transport is: `URLSession` ends an
            // in-flight request when its task is cancelled, and a double that
            // holds on regardless would make `stop()` look like it blocks on
            // work it has already cancelled.
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    heldContinuation = continuation
                }
            } onCancel: {
                Task { await self.releaseHeldRequest() }
            }
            try Task.checkCancellation()
        }
        if !errors.isEmpty, let error = errors.removeFirst() { throw error }
        guard !responses.isEmpty else {
            throw NoResponseQueued(method: method.rawValue, path: path)
        }
        return try JSONDecoder().decode(T.self, from: responses.removeFirst())
    }

    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> ConflictResult<T> {
        .success(try await request(method: method, path: path, body: body, query: query))
    }

    func rawRequest(
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?,
        query: [(String, String)]?
    ) async throws -> (Data, HTTPURLResponse) {
        fatalError("HeldOpenStreamTransport: rawRequest not supported")
    }

    nonisolated func eventStream(
        path: String,
        query: [(String, String)]?,
        lastEventID: String?
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            // Nothing finishes this continuation until the test asks, so the
            // stream models a live one rather than one that closes at once.
            Task {
                await self.registerStream(
                    continuation, path: path, query: query, lastEventID: lastEventID
                )
            }
        }
    }

    private func registerStream(
        _ continuation: AsyncThrowingStream<SSEEvent, Error>.Continuation,
        path: String,
        query: [(String, String)]?,
        lastEventID: String?
    ) {
        recordedCalls.append(
            MockTransport.Call(
                method: .get, path: path, body: nil, query: query, lastEventID: lastEventID
            )
        )
        // A stream registered after the test closed the previous ones is a
        // reconnect, and the test drives those explicitly; leave it open too.
        streamContinuations.append(continuation)
        openStreamCount += 1
    }
}

/// Envelope for the single-edge shapes this file's doubles emit — the
/// response body of an edge create, and the `edge.created` event payload.
private struct EdgeEnvelope: Codable {
    let edge: Edge
}

/// The edge-create body as it arrives on the wire, so a double can answer
/// the request it was actually sent. `id` is optional because the whole
/// question a test puts to this transport is whether it was there.
private struct SentEdgeCreate: Decodable {
    let id: String?
    let sourceId: String
    let targetId: String
    let edgeType: String

    enum CodingKeys: String, CodingKey {
        case id
        case sourceId = "source_id"
        case targetId = "target_id"
        case edgeType = "edge_type"
    }
}

/// The bulk-edge body, read for the same reason.
private struct SentBulkEdges: Decodable {
    let edges: [SentEdgeCreate]
    let emitEvents: Bool?

    enum CodingKeys: String, CodingKey {
        case edges
        case emitEvents = "emit_events"
    }
}

/// A server that keeps the ids it is given, and mints one where it is not.
///
/// `MockTransport` answers with whatever the test enqueued, which leaves the
/// id on the wire and the id in the answer independent of each other — and
/// the two diverging is the entire defect, so a test built on canned answers
/// passes whether or not the request carried an id. This double derives its
/// answer from the request the way the routes do: a create carrying an `id`
/// is stored under it, one without gets a server-minted id, and the
/// `edge.created` echo carries whichever was used. A store fed by this
/// transport can end up holding two rows for one edge, which is what the
/// defect looks like from the device.
///
/// Both edge-create doors are modeled, because both had the defect.
/// `POST /edges/bulk` echoes only when the call set `emit_events`, as the
/// route does — a double that echoed regardless would be asserting against
/// events a real server never sends.
///
/// Echoes are delivered when the stream opens rather than concurrently,
/// which is the real order: coming online drains the queue before it
/// subscribes, so every create this transport has seen has already happened
/// by the time it is asked for a stream.
actor EdgeMintingTransport: Transport {

    /// Stamped onto every answer. The local store mints neither, so either
    /// one appearing in a row proves the row came from the server's copy.
    static let spaceId = "space-1"
    static let stampedAt = "2026-09-02T00:00:00.000Z"

    private var recordedCalls: [MockTransport.Call] = []
    private var echoes: [Edge] = []
    private var mintCount = 0
    /// Edge types the server refuses, with the code it answers per entry.
    private var refusals: [String: (code: String, message: String)] = [:]

    /// Declares that edges of `edgeType` are refused, so the bulk door
    /// answers an `errored` entry for them the way the route does.
    func refuse(edgeType: String, code: String, message: String = "refused") {
        refusals[edgeType] = (code, message)
    }

    struct UnsupportedRequest: Error, CustomStringConvertible {
        let method: String
        let path: String
        var description: String {
            "EdgeMintingTransport: only the edge-create doors are modeled, got \(method) \(path)"
        }
    }

    var calls: [MockTransport.Call] { recordedCalls }

    /// Sequential rather than random, so a failing run names the same id
    /// every time and a diff of the message is readable.
    private func mintId() -> String {
        mintCount += 1
        return String(format: "01a00000-0000-7000-8000-%012d", mintCount)
    }

    private func store(_ sent: SentEdgeCreate, echo: Bool) -> Edge {
        let edge = Edge(
            createdAt: Self.stampedAt,
            edgeType: sent.edgeType,
            id: sent.id ?? mintId(),
            properties: [:],
            sourceId: sent.sourceId,
            spaceId: Self.spaceId,
            targetId: sent.targetId,
            updatedAt: Self.stampedAt
        )
        if echo { echoes.append(edge) }
        return edge
    }

    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T {
        let bodyData = body.flatMap { try? JSONEncoder().encode(AnyEncodable($0)) }
        recordedCalls.append(
            MockTransport.Call(method: method, path: path, body: bodyData, query: query)
        )
        guard method == .post, let bodyData else {
            throw UnsupportedRequest(method: method.rawValue, path: path)
        }

        switch path {
        case "/edges":
            let sent = try JSONDecoder().decode(SentEdgeCreate.self, from: bodyData)
            let edge = store(sent, echo: true)
            return try JSONDecoder().decode(
                T.self, from: try JSONEncoder().encode(EdgeEnvelope(edge: edge))
            )

        case "/edges/bulk":
            let sent = try JSONDecoder().decode(SentBulkEdges.self, from: bodyData)
            let emit = sent.emitEvents ?? false
            var entries: [BulkEdgeResultEntry] = []
            var created = 0, errored = 0
            for (index, raw) in sent.edges.enumerated() {
                if let refusal = refusals[raw.edgeType] {
                    entries.append(BulkEdgeResultEntry(
                        index: index, outcome: .errored, id: nil, reason: nil,
                        error: BulkResultError(code: refusal.code, message: refusal.message)
                    ))
                    errored += 1
                    continue
                }
                let edge = store(raw, echo: emit)
                entries.append(
                    BulkEdgeResultEntry(index: index, outcome: .created, id: edge.id)
                )
                created += 1
            }
            let result = BulkEdgeResult(
                counts: BulkResultCounts(
                    created: created, updated: 0, skipped: 0, errored: errored
                ),
                results: entries
            )
            return try JSONDecoder().decode(
                T.self, from: try JSONEncoder().encode(result)
            )

        default:
            throw UnsupportedRequest(method: method.rawValue, path: path)
        }
    }

    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> ConflictResult<T> {
        .success(try await request(method: method, path: path, body: body, query: query))
    }

    func rawRequest(
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?,
        query: [(String, String)]?
    ) async throws -> (Data, HTTPURLResponse) {
        throw UnsupportedRequest(method: method.rawValue, path: path)
    }

    nonisolated func eventStream(
        path: String,
        query: [(String, String)]?,
        lastEventID: String?
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for (index, edge) in await self.pendingEchoes().enumerated() {
                    guard
                        let data = try? JSONEncoder().encode(EdgeEnvelope(edge: edge)),
                        let text = String(data: data, encoding: .utf8)
                    else { continue }
                    continuation.yield(
                        SSEEvent(id: "evt-\(index + 1)", event: "edge.created", data: text)
                    )
                }
                continuation.finish()
            }
        }
    }

    private func pendingEchoes() -> [Edge] { echoes }
}

/// Envelope for the single-item shapes this file's doubles emit — the
/// `item.created` event payload the bulk route publishes when asked to.
private struct ItemEnvelope: Codable {
    let item: Item
}

/// The bulk-item body as it arrives on the wire, so a double can answer the
/// request it was actually sent. `id` is optional because the whole question
/// a test puts to this transport is whether it was there.
private struct SentBulkItem: Decodable {
    let id: String?
    let type: String
}

private struct SentBulkItems: Decodable {
    let items: [SentBulkItem]
    let emitEvents: Bool?
    let mode: String?
    let atomic: Bool?

    enum CodingKeys: String, CodingKey {
        case items, mode, atomic
        case emitEvents = "emit_events"
    }
}

/// A server that keeps the item ids it is given, and mints one where it is
/// not.
///
/// The item counterpart to ``EdgeMintingTransport``, and it exists for the
/// same reason: `MockTransport` answers with whatever the test enqueued, which
/// leaves the id on the wire and the id in the answer independent of each
/// other — and the two diverging is the entire defect, so a test built on
/// canned answers passes whether or not the request carried an id. This double
/// derives its answer from the request the way the route does.
///
/// `POST /items/bulk` echoes only when the call set `emit_events`, as the
/// route does: it defaults off so a bulk page does not fan out per-item
/// webhooks. Echoes are delivered when the stream opens rather than
/// concurrently, which is the real order — coming online drains the queue
/// before it subscribes.
actor ItemMintingTransport: Transport {

    /// Stamped onto every answer. The local store mints neither, so either
    /// one appearing in a row proves the row came from the server's copy.
    static let spaceId = "space-1"
    static let stampedAt = "2026-09-02T00:00:00.000Z"

    private var recordedCalls: [MockTransport.Call] = []
    private var echoes: [Item] = []
    private var mintCount = 0
    /// Ids this server already holds, so a second page naming one resolves
    /// rather than creating. Seeded by ``hold(_:)`` and grown by every create.
    private var held: Set<String> = []
    /// Types the server refuses, by entry `type`. Keyed on the type because it
    /// is the field a test can vary per entry without touching ids.
    private var refusals: [String: Refusal] = [:]
    /// Ids the server answers with a different id than it was sent.
    private var resolutions: [String: String] = [:]
    /// Added to every answered index, so a test can produce the one shape
    /// nothing else can: an answer that does not line up with the page it
    /// was sent. A real server would not, which is exactly why the engine's
    /// guard against it is otherwise unreachable.
    private var answerIndexOffset = 0

    func answerIndexOffsetForTesting(_ offset: Int) { answerIndexOffset = offset }

    struct Refusal: Sendable {
        let code: String
        let message: String
    }

    struct UnsupportedRequest: Error, CustomStringConvertible {
        let method: String
        let path: String
        var description: String {
            "ItemMintingTransport: only the item bulk door is modeled, got \(method) \(path)"
        }
    }

    /// Declares an id the server already holds, so a page naming it resolves
    /// to an existing row instead of creating one.
    func hold(_ id: String) { held.insert(id) }

    /// Declares that an entry sent under `sentId` resolves to a row the
    /// server holds under a different id, which is what an upsert matching on
    /// `(source, source_id)` does. Without this the double answered every id
    /// with itself, so a test could not tell a client that leaves a divergent
    /// id alone from one that repairs it.
    func resolve(_ sentId: String, to serverId: String) {
        resolutions[sentId] = serverId
        held.insert(sentId)
    }

    /// Declares that entries of `type` are refused, with the code the route
    /// would answer per entry.
    func refuse(type: String, code: String, message: String = "refused") {
        refusals[type] = Refusal(code: code, message: message)
    }

    fileprivate func refusal(for item: SentBulkItem) -> Refusal? {
        refusals[item.type]
    }

    fileprivate func firstRefusal(in items: [SentBulkItem]) -> (Int, Refusal)? {
        for (index, item) in items.enumerated() {
            if let refusal = refusals[item.type] { return (index, refusal) }
        }
        return nil
    }

    var calls: [MockTransport.Call] { recordedCalls }

    /// Sequential rather than random, so a failing run names the same id every
    /// time and a diff of the message is readable.
    private func mintId() -> String {
        mintCount += 1
        return String(format: "01b00000-0000-7000-8000-%012d", mintCount)
    }

    private func store(_ sent: SentBulkItem, echo: Bool) -> Item {
        let item = Item(
            createdAt: Self.stampedAt,
            id: sent.id ?? mintId(),
            properties: [:],
            schemaVersion: 1,
            source: "test",
            spaceId: Self.spaceId,
            state: .active,
            tier: .feed,
            timestamp: Self.stampedAt,
            type: sent.type,
            updatedAt: Self.stampedAt,
            version: 1
        )
        held.insert(item.id)
        if echo { echoes.append(item) }
        return item
    }

    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T {
        let bodyData = body.flatMap { try? JSONEncoder().encode(AnyEncodable($0)) }
        recordedCalls.append(
            MockTransport.Call(method: method, path: path, body: bodyData, query: query)
        )
        guard method == .post, path == "/items/bulk", let bodyData else {
            throw UnsupportedRequest(method: method.rawValue, path: path)
        }

        let sent = try JSONDecoder().decode(SentBulkItems.self, from: bodyData)
        let emit = sent.emitEvents ?? false
        let createOnly = sent.mode == "create_only"
        // `atomic` defaults to true on the route, so a page that says nothing
        // is atomic and one refused entry rolls the whole thing back.
        let atomic = sent.atomic ?? true

        // Atomic mode answers the first refusal and writes nothing, so it is
        // resolved before any row is stored.
        if atomic, let (index, refusal) = firstRefusal(in: sent.items) {
            // Built as the body the route writes and parsed the way the real
            // transport parses it, rather than handed over as a ready-made
            // error. The difference is the whole point: a hand-built error
            // skips `parseMarfaError`, which is where a 400's code is
            // decided, so a test using one passes whether or not the SDK can
            // read a rollback off the wire at all.
            let details = "{\"index\":\(index),\"code\":\"\(refusal.code)\",\"message\":\"\(refusal.message)\"}"
            let body = "{\"error\":{\"code\":\"bulk_atomic_rollback\",\"message\":\"Bulk upsert rolled back on item \(index)\",\"details\":\(details)}}"
            throw parseMarfaError(data: Data(body.utf8), statusCode: 400)
        }

        var entries: [BulkResultEntry] = []
        var created = 0, updated = 0, skipped = 0, errored = 0
        for (index, raw) in sent.items.enumerated() {
            if let refusal = refusal(for: raw) {
                entries.append(BulkResultEntry(
                    index: index, outcome: .errored, id: nil, reason: nil,
                    error: BulkResultError(code: refusal.code, message: refusal.message)
                ))
                errored += 1
                continue
            }
            // An id this double already holds is a row that resolves: under
            // `create_only` the route skips it with `duplicate_id`, otherwise
            // it updates in place. Neither writes a new row, so neither
            // echoes one.
            if let id = raw.id, held.contains(id) {
                let answered = resolutions[id] ?? id
                if createOnly {
                    entries.append(BulkResultEntry(
                        index: index, outcome: .skipped, id: answered,
                        reason: "duplicate_id", error: nil
                    ))
                    skipped += 1
                } else {
                    entries.append(BulkResultEntry(
                        index: index, outcome: .updated, id: answered,
                        reason: nil, error: nil
                    ))
                    updated += 1
                }
                continue
            }
            let item = store(raw, echo: emit)
            entries.append(BulkResultEntry(
                index: index, outcome: .created, id: item.id, reason: nil, error: nil
            ))
            created += 1
        }
        let result = BulkResult(
            counts: BulkResultCounts(
                created: created, updated: updated, skipped: skipped, errored: errored
            ),
            results: answerIndexOffset == 0 ? entries : entries.map {
                BulkResultEntry(
                    index: $0.index + answerIndexOffset, outcome: $0.outcome,
                    id: $0.id, reason: $0.reason, error: $0.error
                )
            },
            blobsImported: nil
        )
        return try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(result))
    }

    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> ConflictResult<T> {
        .success(try await request(method: method, path: path, body: body, query: query))
    }

    func rawRequest(
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?,
        query: [(String, String)]?
    ) async throws -> (Data, HTTPURLResponse) {
        throw UnsupportedRequest(method: method.rawValue, path: path)
    }

    nonisolated func eventStream(
        path: String,
        query: [(String, String)]?,
        lastEventID: String?
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for (index, item) in await self.pendingEchoes().enumerated() {
                    guard
                        let data = try? JSONEncoder().encode(ItemEnvelope(item: item)),
                        let text = String(data: data, encoding: .utf8)
                    else { continue }
                    continuation.yield(
                        SSEEvent(id: "evt-\(index + 1)", event: "item.created", data: text)
                    )
                }
                continuation.finish()
            }
        }
    }

    /// Drains rather than reads. An event is delivered once: the server does
    /// not re-send a create because a client reconnected, and a double that
    /// did would let a test pass on rows the replay never wrote.
    private func pendingEchoes() -> [Item] {
        defer { echoes.removeAll() }
        return echoes
    }
}
