import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

// Shared fixtures and helpers for the split SyncEngine test files
// (MutationQueueTests, MutationQueueUtilityTests, SyncEngineConnectionStateTests,
// SyncEngineSSEAndCursorTests, SyncEngineReplayTests, SyncEngineStateTrackingTests,
// SyncEngineProactiveDrainTests). Namespaced under an enum to avoid colliding
// with same-named private helpers in unrelated suites.
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
    private var heldPath: String?
    private var heldContinuation: CheckedContinuation<Void, Never>?
    private(set) var heldRequestReached = false

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

    /// Suspends the next request to `path` until ``releaseHeldRequest()``.
    /// The engine's coming-online phase is microseconds wide against a mock
    /// and seconds wide against a real library, and this is what lets a test
    /// stand inside it.
    func holdNextRequest(path: String) {
        heldPath = path
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
        if path == heldPath {
            heldPath = nil
            heldRequestReached = true
            await withCheckedContinuation { continuation in
                heldContinuation = continuation
            }
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
