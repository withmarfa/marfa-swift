import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

@Suite("ItemsNamespace — createWithAttachments")
struct ItemsNamespaceAttachmentsTests {

    func makeClient() -> (MymeClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MymeClient(configuration: config, transport: mock)
        return (client, mock)
    }

    // MARK: - Fixtures

    func makeBlobUploadResponseJSON(hash: String, mimeType: String, size: Int) -> Data {
        let payload: [String: Any] = [
            "hash": hash,
            "mime_type": mimeType,
            "size": size
        ]
        return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    func makeItem(id: String, type: String) -> Item {
        Item(
            createdAt: "2026-05-01T00:00:00Z",
            id: id,
            properties: [:],
            schemaVersion: 1,
            source: "test",
            state: .active,
            timestamp: "2026-05-01T00:00:00Z",
            type: type,
            updatedAt: "2026-05-01T00:00:00Z",
            version: 1
        )
    }

    func makeInput(attachmentCount: Int) -> CreateWithAttachmentsInput {
        let attachments = (0..<attachmentCount).map { idx in
            CreateWithAttachmentsInput.Attachment(
                type: "core.file.image",
                data: Data("blob-\(idx)".utf8),
                mimeType: "image/png"
            )
        }
        return CreateWithAttachmentsInput(
            item: BulkItemInput(type: "core.note", properties: ["title": .string("host")]),
            attachments: attachments
        )
    }

    // MARK: - Happy path

    @Test("Happy path: uploads N blobs, runs bulk, hydrates host + attachments")
    func happyPath() async throws {
        let (client, mock) = makeClient()
        let input = makeInput(attachmentCount: 2)

        // Queue two blob uploads (raw responses).
        mock.enqueueRaw(
            data: makeBlobUploadResponseJSON(hash: "sha256:aaa", mimeType: "image/png", size: 6),
            statusCode: 201
        )
        mock.enqueueRaw(
            data: makeBlobUploadResponseJSON(hash: "sha256:bbb", mimeType: "image/png", size: 6),
            statusCode: 201
        )

        // Bulk result (one created entry per item: host + 2 attachments).
        let bulkResult = BulkResult(
            counts: BulkResultCounts(created: 3, updated: 0, skipped: 0, errored: 0),
            results: [
                BulkResultEntry(index: 0, outcome: .created, id: nil, reason: nil, error: nil),
                BulkResultEntry(index: 1, outcome: .created, id: nil, reason: nil, error: nil),
                BulkResultEntry(index: 2, outcome: .created, id: nil, reason: nil, error: nil),
            ],
            blobsImported: 2
        )
        mock.enqueue(bulkResult)

        // Hydration: 3 GETs fan out concurrently via TaskGroup. MockTransport
        // serves responses FIFO regardless of path, so the test can't tie a
        // specific response to a specific id — but the helper's internal
        // index→item join guarantees `result.host` lands first and the
        // attachments follow in input order. Use indistinguishable
        // responses to keep the test deterministic.
        mock.enqueue(ItemResponse(item: makeItem(id: "hydrated", type: "core.note")))
        mock.enqueue(ItemResponse(item: makeItem(id: "hydrated", type: "core.note")))
        mock.enqueue(ItemResponse(item: makeItem(id: "hydrated", type: "core.note")))

        let result = try await client.items.createWithAttachments(input)

        #expect(result.host.id == "hydrated")
        #expect(result.attachments.count == 2)

        // Verify call shapes. Order is: 2 blob uploads, 1 bulk POST, 3 GETs.
        // Blob uploads + bulk are deterministic by enqueue order; the 3 GET
        // hydrations run via TaskGroup so order can interleave — assert by
        // membership instead.
        #expect(mock.calls.count == 6)

        let blobCalls = mock.calls.filter { $0.path == "/blobs" }
        #expect(blobCalls.count == 2)
        #expect(blobCalls.allSatisfy { $0.method == .post })

        let bulkCalls = mock.calls.filter { $0.path == "/items/bulk" }
        #expect(bulkCalls.count == 1)
        #expect(bulkCalls[0].method == .post)

        let itemGets = mock.calls.filter { $0.path.hasPrefix("/items/") && !$0.path.contains("bulk") }
        #expect(itemGets.count == 3)
        #expect(itemGets.allSatisfy { $0.method == .get })
    }

    // MARK: - Failure: blob upload

    @Test("Blob upload failure throws MymeError with blob_upload_failed code")
    func blobUploadFailureThrows() async throws {
        let (client, mock) = makeClient()
        let input = makeInput(attachmentCount: 1)

        // Queue an error for the only blob upload call.
        mock.enqueueError(URLError(.timedOut))

        await #expect(throws: MymeError.self) {
            _ = try await client.items.createWithAttachments(input)
        }

        // Only the blob upload call should have been recorded — no bulk,
        // no hydration.
        let blobCalls = mock.calls.filter { $0.path == "/blobs" }
        #expect(blobCalls.count == 1)
        let bulkCalls = mock.calls.filter { $0.path == "/items/bulk" }
        #expect(bulkCalls.isEmpty)
    }

    @Test("Blob upload failure message annotates the offending attachment index + type")
    func blobUploadFailureAnnotatesIndex() async throws {
        let (client, mock) = makeClient()
        let input = makeInput(attachmentCount: 1)
        mock.enqueueError(URLError(.timedOut))

        do {
            _ = try await client.items.createWithAttachments(input)
            Issue.record("expected throw")
        } catch let error as MymeError {
            #expect(error.code == "blob_upload_failed")
            #expect(error.message.contains("attachments[0]"))
            #expect(error.message.contains("core.file.image"))
        }
    }

    // MARK: - Failure: bulk errored

    @Test("Bulk errored outcome throws ValidationError")
    func bulkErroredThrowsValidationError() async throws {
        let (client, mock) = makeClient()
        let input = makeInput(attachmentCount: 1)

        mock.enqueueRaw(
            data: makeBlobUploadResponseJSON(hash: "sha256:aaa", mimeType: "image/png", size: 6),
            statusCode: 201
        )

        // One attachment item failed.
        let bulkResult = BulkResult(
            counts: BulkResultCounts(created: 0, updated: 0, skipped: 0, errored: 1),
            results: [
                BulkResultEntry(index: 0, outcome: .created, id: "host-id", reason: nil, error: nil),
                BulkResultEntry(
                    index: 1, outcome: .errored, id: nil, reason: nil,
                    error: BulkResultError(code: "schema_violation", message: "missing required field")
                ),
            ],
            blobsImported: nil
        )
        mock.enqueue(bulkResult)

        do {
            _ = try await client.items.createWithAttachments(input)
            Issue.record("expected throw")
        } catch let error as ValidationError {
            #expect(error.status == 400)
            #expect(error.message.contains("index 1"))
            #expect(error.message.contains("missing required field"))
        }
    }

    // MARK: - Failure: bulk skipped

    @Test("Bulk skipped outcome (duplicate id) throws ConflictError")
    func bulkSkippedThrowsConflictError() async throws {
        let (client, mock) = makeClient()
        let input = makeInput(attachmentCount: 1)

        mock.enqueueRaw(
            data: makeBlobUploadResponseJSON(hash: "sha256:aaa", mimeType: "image/png", size: 6),
            statusCode: 201
        )

        let bulkResult = BulkResult(
            counts: BulkResultCounts(created: 0, updated: 0, skipped: 1, errored: 0),
            results: [
                BulkResultEntry(
                    index: 0, outcome: .skipped, id: nil,
                    reason: "duplicate_id", error: nil
                ),
            ],
            blobsImported: nil
        )
        mock.enqueue(bulkResult)

        do {
            _ = try await client.items.createWithAttachments(input)
            Issue.record("expected throw")
        } catch let error as ConflictError {
            #expect(error.status == 409)
            #expect(error.code == "duplicate_id")
            #expect(error.message.contains("index 0"))
        }
    }

    // MARK: - Local mode rejection

    @Test("Pure-local mode rejects createWithAttachments")
    func localModeRejects() async throws {
        let client = try await MymeClient.local(path: ":memory:")
        let input = makeInput(attachmentCount: 1)

        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.items.createWithAttachments(input)
        }
    }
}
