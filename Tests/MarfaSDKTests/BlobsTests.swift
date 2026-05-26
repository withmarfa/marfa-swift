import Testing
import Foundation
import CryptoKit
import SwiftData
@testable import MarfaSDK
import MarfaSDKTestSupport

@Suite("BlobsNamespace")
struct BlobsTests {

    func makeClient() -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let client = MarfaClient(configuration: config, transport: mock)
        return (client, mock)
    }

    /// Returns a synced-mode client backed by an in-memory store, plus
    /// the mock transport so tests can inspect calls.
    func makeSyncedClient() async throws -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let (store, queue, container) = try await MarfaSDKTest.makeInMemoryStorePair()
        let engine = SyncEngine(
            transport: mock,
            localStore: store,
            mutationQueue: queue,
            connectionManager: ConnectionStateManager()
        )
        let client = MarfaClient(
            configuration: config,
            transport: mock,
            localStore: store,
            mutationQueue: queue,
            syncEngine: engine,
            container: container
        )
        return (client, mock)
    }

    /// Computes the expected SHA-256 hash string for a given blob.
    func expectedHash(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }

    @Test("Upload success decodes BlobUploadResponse")
    func uploadSuccess() async throws {
        let (client, mock) = makeClient()
        let body = #"{"hash":"sha256:abc","size":100,"mime_type":"image/png"}"#
        mock.enqueueRaw(data: Data(body.utf8), statusCode: 201)

        let result = try await client.blobs.upload(data: Data([0x89, 0x50, 0x4e, 0x47]), mimeType: "image/png")

        #expect(result.hash == "sha256:abc")
    }

    @Test("Upload 401 produces UnauthorizedError via shared parser")
    func uploadUnauthorized() async throws {
        let (client, mock) = makeClient()
        let body = #"{"error":{"code":"unauthorized","message":"Invalid token"}}"#
        mock.enqueueRaw(data: Data(body.utf8), statusCode: 401)

        await #expect(throws: UnauthorizedError.self) {
            _ = try await client.blobs.upload(data: Data(), mimeType: "image/png")
        }
    }

    @Test("Upload 500 produces base MarfaError with status 500")
    func uploadServerError() async throws {
        let (client, mock) = makeClient()
        let body = #"{"error":{"code":"internal","message":"Database down"}}"#
        mock.enqueueRaw(data: Data(body.utf8), statusCode: 500)

        do {
            _ = try await client.blobs.upload(data: Data(), mimeType: "image/png")
            Issue.record("Expected error")
        } catch let error as MarfaError {
            #expect(error.status == 500)
            #expect(error.message == "Database down")
        }
    }

    @Test("Download 401 produces UnauthorizedError (not NotFoundError)")
    func downloadUnauthorized() async throws {
        let (client, mock) = makeClient()
        let body = #"{"error":{"code":"unauthorized","message":"No key"}}"#
        mock.enqueueRaw(data: Data(body.utf8), statusCode: 401)

        await #expect(throws: UnauthorizedError.self) {
            _ = try await client.blobs.download(hash: "abc")
        }
    }

    @Test("Download 403 produces ForbiddenError")
    func downloadForbidden() async throws {
        let (client, mock) = makeClient()
        let body = #"{"error":{"code":"forbidden","message":"Not allowed"}}"#
        mock.enqueueRaw(data: Data(body.utf8), statusCode: 403)

        await #expect(throws: ForbiddenError.self) {
            _ = try await client.blobs.download(hash: "abc")
        }
    }

    @Test("Download 404 still produces NotFoundError")
    func downloadNotFound() async throws {
        let (client, mock) = makeClient()
        let body = #"{"error":{"code":"not_found","message":"Missing"}}"#
        mock.enqueueRaw(data: Data(body.utf8), statusCode: 404)

        await #expect(throws: NotFoundError.self) {
            _ = try await client.blobs.download(hash: "abc")
        }
    }

    @Test("Download success returns data and content type")
    func downloadSuccess() async throws {
        let (client, mock) = makeClient()
        let payload = Data([0x01, 0x02, 0x03])
        // MockTransport.enqueueRaw sets Content-Type to application/json;
        // the download method still reads it from the response header.
        mock.enqueueRaw(data: payload, statusCode: 200)

        let (data, contentType) = try await client.blobs.download(hash: "abc")

        #expect(data == payload)
        #expect(contentType == "application/json")
    }

    // MARK: - Queued upload (synced mode)

    @Test("Synced upload returns predicted hash immediately without hitting transport")
    func syncedUploadQueues() async throws {
        let (client, mock) = try await makeSyncedClient()
        let imageData = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])  // PNG header

        let result = try await client.blobs.upload(data: imageData, mimeType: "image/png")

        // Hash matches local SHA-256 computation.
        #expect(result.hash == expectedHash(of: imageData))
        #expect(result.mimeType == "image/png")
        #expect(result.size == imageData.count)
        // No transport call made — upload was queued, not sent.
        #expect(mock.calls.isEmpty)
    }

    @Test("Synced upload enqueues uploadBlob mutation with blob data in store")
    func syncedUploadPersistsData() async throws {
        let (store, queue, container) = try await MarfaSDKTest.makeInMemoryStorePair()
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let engine = SyncEngine(
            transport: mock, localStore: store, mutationQueue: queue,
            connectionManager: ConnectionStateManager()
        )
        let client = MarfaClient(
            configuration: config, transport: mock,
            localStore: store, mutationQueue: queue, syncEngine: engine, container: container
        )

        let imageData = Data(repeating: 0xAB, count: 64)
        let hash = expectedHash(of: imageData)

        _ = try await client.blobs.upload(data: imageData, mimeType: "image/jpeg")

        // One uploadBlob record is in the mutation queue.
        let pending = try await queue.fetchAll()
        #expect(pending.count == 1)
        #expect(pending[0].kind == .uploadBlob)

        // Blob data is retrievable by hash.
        let stored = try await queue.fetchPendingBlob(hash: hash)
        #expect(stored == imageData)
    }

    @Test("SyncEngine replays uploadBlob mutation and cleans up pending blob data")
    func syncEngineReplaysUploadBlob() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        let mock = MockTransport()
        let connManager = ConnectionStateManager()

        let imageData = Data([0x01, 0x02, 0x03, 0x04])
        let hash = expectedHash(of: imageData)

        // Enqueue a blob upload directly via the queue (simulates offline capture).
        try await queue.enqueueBlobUpload(hash: hash, data: imageData, mimeType: "image/png")

        // Stub the transport: POST /blobs → 201 with the matching hash.
        let responseBody = #"{"hash":"\#(hash)","mime_type":"image/png","size":4}"#
        mock.enqueueRaw(data: Data(responseBody.utf8), statusCode: 201)
        // SSE stream closes immediately (no events).
        mock.enqueueEvents([])

        let engine = SyncEngine(
            transport: mock, localStore: store, mutationQueue: queue,
            connectionManager: connManager
        )
        await engine.setReconnectDelaysForTesting(base: 0.01, max: 0.01)
        await engine.start()

        // Flip to connecting so the engine opens the (empty) SSE stream and
        // then drains the mutation queue.
        await connManager.markConnecting()

        // Wait for the mutation queue to drain.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let isEmpty = (try? await queue.isEmpty) ?? false
            if isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        await engine.stop()

        // Queue is drained.
        #expect((try? await queue.isEmpty) == true)

        // Transport received the POST /blobs call with the right content.
        let blobCall = mock.calls.first { $0.path == "/blobs" }
        #expect(blobCall != nil)

        // Pending blob data was deleted after successful upload.
        let residual = try await queue.fetchPendingBlob(hash: hash)
        #expect(residual == nil)
    }

    @Test("SyncEngine drops uploadBlob permanently when blob data is missing")
    func syncEngineDropsMissingBlobData() async throws {
        let (store, queue, container) = try await MarfaSDKTest.makeInMemoryStorePair()
        let mock = MockTransport()
        let connManager = ConnectionStateManager()

        let hash = "sha256:deadbeef"
        // Insert the mutation record directly but omit the
        // PendingBlobModel row, simulating a corrupted or partially-
        // written store. We open a fresh @MainActor `ModelContext`
        // against the shared container; the save commits to the same
        // SQLite file that `MutationQueue.fetchPendingBlob` reads from.
        let payload = #"{"hash":"\#(hash)","mimeType":"image/png","size":4}"#
        try await Task { @MainActor in
            let context = ModelContext(container)
            let mutation = PendingMutationModel()
            mutation.id = UUID().uuidString.lowercased()
            mutation.kindRaw = MutationKind.uploadBlob.rawValue
            mutation.payloadJson = payload
            mutation.sourceId = nil
            mutation.localId = nil
            mutation.createdAt = Date().ISO8601Format(.init(includingFractionalSeconds: true))
            mutation.attemptCount = 0
            mutation.lastError = nil
            context.insert(mutation)
            try context.save()
        }.value

        // SSE stream closes immediately.
        mock.enqueueEvents([])

        let engine = SyncEngine(
            transport: mock, localStore: store, mutationQueue: queue,
            connectionManager: connManager
        )
        await engine.setReconnectDelaysForTesting(base: 0.01, max: 0.01)
        await engine.start()

        // Subscribe before triggering the cycle so we catch the drop event.
        let events = await engine.events
        let collector = Task { () -> [SyncEvent] in
            var out: [SyncEvent] = []
            for await event in events {
                out.append(event)
                if case .mutationDropped = event { return out }
                if case .synced = event { return out }
            }
            return out
        }

        await connManager.markConnecting()

        let collected = try await withThrowingTaskGroup(of: [SyncEvent].self) { group in
            group.addTask { try await collector.value }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return []
            }
            let result = try await group.next() ?? []
            group.cancelAll()
            return result
        }
        await engine.stop()

        // The mutation was permanently dropped, not retried.
        let droppedKinds = collected.compactMap { event -> String? in
            if case .mutationDropped(let kind, _, _, _) = event { return kind }
            return nil
        }
        #expect(droppedKinds.contains("uploadBlob"))
        #expect((try? await queue.isEmpty) == true)
        // No actual upload was attempted.
        #expect(mock.calls.filter { $0.path == "/blobs" }.isEmpty)
    }

    @Test("Network-only client uploads directly without queuing")
    func networkOnlyClientUploadsDirectly() async throws {
        let (client, mock) = makeClient()
        let imageData = Data([0x89, 0x50, 0x4e, 0x47])
        let body = #"{"hash":"sha256:abc","size":4,"mime_type":"image/png"}"#
        mock.enqueueRaw(data: Data(body.utf8), statusCode: 201)

        let result = try await client.blobs.upload(data: imageData, mimeType: "image/png")

        // Result comes from the server response, not local computation.
        #expect(result.hash == "sha256:abc")
        // Transport was called.
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].path == "/blobs")
    }
}
