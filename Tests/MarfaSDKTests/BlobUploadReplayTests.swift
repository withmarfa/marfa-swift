import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport
import SwiftData

/// Replay semantics for a queued blob upload whose bytes are no longer
/// in the pending table.
///
/// A pending blob row is deleted in exactly one place: after the server
/// has accepted the bytes. So finding no row is not evidence of loss, it
/// is evidence the upload already happened. Enqueuing the same hash twice
/// while offline produces that state on the second drain, and reporting it
/// as a failed upload told applications a blob had been lost when it had
/// landed.
@Suite("Blob upload replay", .timeLimit(.minutes(1)))
@MainActor
struct BlobUploadReplayTests {

    private func makeFixture() async throws -> (
        queue: MutationQueue,
        transport: MockTransport,
        connManager: ConnectionStateManager,
        engine: SyncEngine
    ) {
        let (localStore, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
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
        return (queue, transport, connManager, engine)
    }

    @Test("the same blob enqueued twice uploads once and drops nothing")
    func duplicateEnqueueIsNotAFailure() async throws {
        let (queue, transport, connManager, engine) = try await makeFixture()

        let hash = "sha256:dedupe01"
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let body = "{\"hash\":\"\(hash)\",\"mime_type\":\"application/octet-stream\",\"size\":4}"
            .data(using: .utf8)!
        transport.enqueueEvents([])
        // One accepted upload, then a HEAD answering that the server holds
        // the blob. The second mutation must resolve on that answer rather
        // than by re-sending bytes it no longer has.
        transport.enqueueRaw(data: body, statusCode: 201)
        transport.enqueueRaw(data: Data(), statusCode: 200)

        // Two mutations, one blob row — the shape a repeated offline write
        // produces.
        try await queue.enqueueBlobUpload(
            hash: hash, data: bytes, mimeType: "application/octet-stream"
        )
        try await queue.enqueueBlobUpload(
            hash: hash, data: bytes, mimeType: "application/octet-stream"
        )

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await awaitCondition(description: "(try? await queue.isEmpty) == true") {
            (try? await queue.isEmpty) == true
        }

        // The substance: the second mutation resolved as already-complete
        // rather than being dropped as a permanent failure. A dropped record
        // here is the application-visible symptom — it is what surfaced as
        // "upload cannot be replayed" for a blob that had in fact uploaded.
        let dropped = try await queue.fetchDropped()
        #expect(dropped.isEmpty, "no mutation should be dropped: \(dropped.map(\.kind))")

        // And it did not re-send: one upload for one distinct blob.
        let uploads = transport.calls.filter { $0.path == "/blobs" }
        #expect(uploads.count == 1)
    }
}
