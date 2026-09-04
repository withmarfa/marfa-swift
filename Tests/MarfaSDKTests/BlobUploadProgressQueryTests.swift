import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport
import SwiftData

/// Tests for ``BlobUploadProgressQuery`` — the reactive projection of
/// the sync engine's `blobUpload*` events.
@Suite("BlobUploadProgressQuery", .timeLimit(.minutes(1)))
@MainActor
struct BlobUploadProgressQueryTests {

    /// Builds a fixture with a live ``SyncEngine`` the query can
    /// subscribe to. Empty SSE stream + short debounce so the engine
    /// transitions to `.online` quickly.
    private func makeFixture() async throws -> (
        store: MarfaStore,
        queue: MutationQueue,
        transport: MockTransport,
        connManager: ConnectionStateManager,
        engine: SyncEngine
    ) {
        let (localStore, queue, container) = try await MarfaSDKTest.makeInMemoryStorePair()
        // A device that has been running, not a cold start: without the
        // stamp the engine imports when it comes online and this suite's
        // response queue answers a call it never meant to make.
        try await SyncEngineTestKit.markImported(queue)
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: localStore,
            mutationQueue: queue,
            connectionManager: connManager,
            drainDebounceInterval: .milliseconds(20)
        )
        let store = MarfaStore(container: container, localStore: localStore, syncEngine: engine)
        return (store, queue, transport, connManager, engine)
    }

    @Test("successful upload progresses from started through completion, then evicts")
    func successfulUploadEvicts() async throws {
        let (store, queue, transport, connManager, engine) = try await makeFixture()
        let query = try #require(store.queryBlobUploadProgress())

        // Server accepts the upload.
        let hash = "sha256:aabbcc"
        let body = "{\"hash\":\"\(hash)\",\"mime_type\":\"application/octet-stream\",\"size\":4}".data(using: .utf8)!
        transport.enqueueEvents([])
        transport.enqueueRaw(data: body, statusCode: 201)

        try await queue.enqueueBlobUpload(
            hash: hash, data: Data([0x01, 0x02, 0x03, 0x04]),
            mimeType: "application/octet-stream"
        )

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        // Wait for the queue to drain — signals the upload completed
        // end-to-end. `query.uploads[hash] == nil` is also true BEFORE
        // the upload starts (the entry is created on
        // `blobUploadStarted`), so we can't use it alone.
        try await awaitCondition(description: "(try? await queue.isEmpty) == true") {
            (try? await queue.isEmpty) == true
        }

        // After eviction-on-complete the entry is gone from the query.
        // The full chain — drain done, engine emits blobUploadCompleted,
        // query observer reacts, eviction runs — resolves in <50ms locally
        // but takes longer on the slower CI runner; 5s is the headroom
        // ceiling.
        try await awaitCondition(description: "query.uploads[hash] == nil") {
            query.uploads[hash] == nil
        }

        await engine.stop()
        query.stop()
    }

    @Test("transient failure leaves a .failed entry observable")
    func transientFailureLeavesFailedEntry() async throws {
        let (store, queue, transport, connManager, engine) = try await makeFixture()
        let query = try #require(store.queryBlobUploadProgress())

        let hash = "sha256:deadbeef"
        transport.enqueueEvents([])
        // Transport error — mid-replay will throw, emit blobUploadFailed.
        transport.enqueueError(
            NetworkError(NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "offline"]))
        )

        try await queue.enqueueBlobUpload(
            hash: hash, data: Data([0xde, 0xad]),
            mimeType: "application/octet-stream"
        )

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        // Wait for the failure to land.
        try await awaitCondition(description: "query.uploads[hash]?.state is .failed") {
            if case .failed = query.uploads[hash]?.state { return true }
            return false
        }

        // Entry persists on failure so the consumer can render the error.
        let entry = try #require(query.uploads[hash])
        if case let .failed(err) = entry.state {
            #expect(err.message.contains("offline") || err.code.isEmpty == false)
        } else {
            Issue.record("expected .failed state, got \(entry.state)")
        }

        // Queue retains the row for retry (transient, not permanent).
        #expect(try await queue.isEmpty == false)

        await engine.stop()
        query.stop()
    }
}
