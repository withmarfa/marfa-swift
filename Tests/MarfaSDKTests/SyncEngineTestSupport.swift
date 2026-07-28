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

    // Build a full synced client fixture.
    static func makeFixture() async throws -> (
        store: LocalStore,
        queue: MutationQueue,
        transport: MockTransport,
        connManager: ConnectionStateManager,
        engine: SyncEngine
    ) {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
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
    static func makeFixtureWithShortDebounce() async throws -> (
        store: LocalStore,
        queue: MutationQueue,
        transport: MockTransport,
        connManager: ConnectionStateManager,
        engine: SyncEngine
    ) {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
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

    // Simple polling helper — SSE consumption is task-driven and can't be
    // pinned to a known deadline. Poll until `condition` returns true or
    // the timeout elapses. Keeps tests deterministic without hard sleeps.
    static func waitUntil(
        timeout: Duration,
        every: Duration = .milliseconds(10),
        _ condition: @Sendable () async throws -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if try await condition() { return }
            try await Task.sleep(for: every)
        }
        if try await condition() { return }
        Issue.record("waitUntil: condition never satisfied within \(timeout)")
    }

    /// The inverse of ``waitUntil``: proves something does *not* happen while
    /// the window is open. Used for lifecycle invariants a regression breaks
    /// immediately — a missing wait or guard publishes state within a couple
    /// of actor hops, so a window measured in hundreds of milliseconds is
    /// decisive rather than a timing gamble.
    static func expectRemainsFalse(
        for duration: Duration,
        every: Duration = .milliseconds(10),
        _ condition: @Sendable () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            if try await condition() {
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
