import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

@Suite("bulkAll chunking helpers")
struct BulkAllTests {

    func makeClient() -> (MymeClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let client = MymeClient(configuration: config, transport: mock)
        return (client, mock)
    }

    /// Helper: canned `BulkResult` with `count` created entries starting at index 0.
    /// `bulkAll` rewrites entry indices to absolute — the per-batch server
    /// would use local indices, so the fixture does too.
    func itemBatch(count: Int) -> BulkResult {
        BulkResult(
            counts: BulkResultCounts(
                created: count, updated: 0, skipped: 0, errored: 0
            ),
            results: (0..<count).map { i in
                BulkResultEntry(
                    index: i, outcome: .created, id: "itm_\(i)",
                    reason: nil, error: nil
                )
            },
            blobsImported: nil
        )
    }

    func edgeBatch(count: Int) -> BulkEdgeResult {
        BulkEdgeResult(
            counts: BulkResultCounts(
                created: count, updated: 0, skipped: 0, errored: 0
            ),
            results: (0..<count).map { i in
                BulkEdgeResultEntry(
                    index: i, outcome: .created, id: "edg_\(i)"
                )
            }
        )
    }

    // MARK: - items.bulkAll

    @Test("items.bulkAll — empty input short-circuits with zero counts, no network call")
    func itemsBulkAllEmpty() async throws {
        let (client, mock) = makeClient()

        let result = try await client.items.bulkAll([])

        #expect(result.counts.created == 0)
        #expect(result.results.isEmpty)
        #expect(mock.calls.isEmpty)
    }

    @Test("items.bulkAll — single batch below batchSize makes one call")
    func itemsBulkAllSingleBatch() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(itemBatch(count: 3))

        let input = (0..<3).map { i in
            BulkItemInput(type: "core.note", sourceId: "src-\(i)")
        }
        let result = try await client.items.bulkAll(input, batchSize: 10)

        #expect(result.counts.created == 3)
        #expect(result.results.count == 3)
        #expect(mock.calls.count == 1)
    }

    @Test("items.bulkAll — multi-batch aggregates counts and rewrites indices to absolute")
    func itemsBulkAllMultiBatch() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(itemBatch(count: 2))
        mock.enqueue(itemBatch(count: 2))
        mock.enqueue(itemBatch(count: 1))

        let input = (0..<5).map { i in
            BulkItemInput(type: "core.note", sourceId: "src-\(i)")
        }
        let result = try await client.items.bulkAll(input, batchSize: 2)

        #expect(result.counts.created == 5)
        #expect(result.results.count == 5)
        // Absolute indices preserved in aggregation order.
        #expect(result.results.map { $0.index } == [0, 1, 2, 3, 4])
        #expect(mock.calls.count == 3)
        for call in mock.calls {
            #expect(call.path == "/items/bulk")
        }
    }

    @Test("items.bulkAll — progressHandler fires once per batch with absolute counts")
    func itemsBulkAllProgressHandler() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(itemBatch(count: 2))
        mock.enqueue(itemBatch(count: 2))
        mock.enqueue(itemBatch(count: 1))

        let input = (0..<5).map { i in
            BulkItemInput(type: "core.note", sourceId: "src-\(i)")
        }
        let progress = ProgressRecorder()
        _ = try await client.items.bulkAll(
            input,
            batchSize: 2,
            progressHandler: { completed, total in
                progress.record(completed: completed, total: total)
            }
        )

        let captured = progress.snapshot()
        #expect(captured.count == 3)
        #expect(captured[0] == (2, 5))
        #expect(captured[1] == (4, 5))
        #expect(captured[2] == (5, 5))
    }

    @Test("items.bulkAll — non-atomic batch failure lands as errored entries, iteration continues")
    func itemsBulkAllNonAtomicFailure() async throws {
        let (client, mock) = makeClient()
        // MockTransport dequeues errors before responses — the first
        // batch therefore consumes the error, subsequent batches land on
        // the enqueued successes. Arrange fixtures around that ordering.
        mock.enqueueError(ValidationError(message: "bad batch"))
        mock.enqueue(itemBatch(count: 2))
        mock.enqueue(itemBatch(count: 1))

        let input = (0..<5).map { i in
            BulkItemInput(type: "core.note", sourceId: "src-\(i)")
        }
        let result = try await client.items.bulkAll(input, batchSize: 2, atomic: false)

        // Batch 1 (slice 0-1) errors → two synthesized errored entries.
        // Batch 2 (slice 2-3) creates 2. Batch 3 (slice 4) creates 1.
        #expect(result.counts.created == 3)
        #expect(result.counts.errored == 2)
        #expect(result.results.count == 5)
        #expect(result.results[0].outcome == .errored)
        #expect(result.results[1].outcome == .errored)
        #expect(result.results[2].outcome == .created)
        #expect(result.results[3].outcome == .created)
        #expect(result.results[4].outcome == .created)
        #expect(mock.calls.count == 3)
    }

    @Test("items.bulkAll — atomic batch failure throws the underlying error")
    func itemsBulkAllAtomicFailure() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(itemBatch(count: 2))
        mock.enqueueError(ValidationError(message: "bad batch"))

        let input = (0..<4).map { i in
            BulkItemInput(type: "core.note", sourceId: "src-\(i)")
        }

        await #expect(throws: ValidationError.self) {
            _ = try await client.items.bulkAll(input, batchSize: 2, atomic: true)
        }
    }

    @Test("items.bulkAll — batchSize clamps to the server's 5000 per-call cap")
    func itemsBulkAllBatchSizeClamp() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(itemBatch(count: 10))

        let input = (0..<10).map { i in
            BulkItemInput(type: "core.note", sourceId: "src-\(i)")
        }
        _ = try await client.items.bulkAll(input, batchSize: 100_000)

        // One batch because clamp-to-5000 still exceeds 10 input items.
        #expect(mock.calls.count == 1)
    }

    @Test("items.bulkAll — batchSize zero or negative clamps up to 1")
    func itemsBulkAllBatchSizeFloor() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(itemBatch(count: 1))
        mock.enqueue(itemBatch(count: 1))

        let input = (0..<2).map { i in
            BulkItemInput(type: "core.note", sourceId: "src-\(i)")
        }
        _ = try await client.items.bulkAll(input, batchSize: 0)

        // Clamp-to-1 means one call per item — two calls for two items.
        #expect(mock.calls.count == 2)
    }

    // MARK: - edges.bulkAll

    @Test("edges.bulkAll — empty input short-circuits with zero counts")
    func edgesBulkAllEmpty() async throws {
        let (client, mock) = makeClient()

        let result = try await client.edges.bulkAll([])

        #expect(result.counts.created == 0)
        #expect(result.results.isEmpty)
        #expect(mock.calls.isEmpty)
    }

    @Test("edges.bulkAll — multi-batch aggregates and posts to /edges/bulk each time")
    func edgesBulkAllMultiBatch() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(edgeBatch(count: 2))
        mock.enqueue(edgeBatch(count: 2))
        mock.enqueue(edgeBatch(count: 1))

        let input = (0..<5).map { i in
            BulkEdgeInputItem(
                sourceId: "src-\(i)",
                targetId: "tgt-\(i)",
                edgeType: "about"
            )
        }
        let result = try await client.edges.bulkAll(input, batchSize: 2)

        #expect(result.counts.created == 5)
        #expect(result.results.count == 5)
        #expect(result.results.map { $0.index } == [0, 1, 2, 3, 4])
        #expect(mock.calls.count == 3)
        for call in mock.calls {
            #expect(call.path == "/edges/bulk")
        }
    }

    @Test("edges.bulkAll — progressHandler fires once per batch")
    func edgesBulkAllProgressHandler() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(edgeBatch(count: 3))
        mock.enqueue(edgeBatch(count: 2))

        let input = (0..<5).map { i in
            BulkEdgeInputItem(
                sourceId: "src-\(i)",
                targetId: "tgt-\(i)",
                edgeType: "about"
            )
        }
        let progress = ProgressRecorder()
        _ = try await client.edges.bulkAll(
            input,
            batchSize: 3,
            progressHandler: { completed, total in
                progress.record(completed: completed, total: total)
            }
        )

        let captured = progress.snapshot()
        #expect(captured.count == 2)
        #expect(captured[0] == (3, 5))
        #expect(captured[1] == (5, 5))
    }

    @Test("edges.bulkAll — non-atomic batch failure lands as errored entries")
    func edgesBulkAllNonAtomicFailure() async throws {
        let (client, mock) = makeClient()
        // MockTransport dequeues errors before responses (see
        // `itemsBulkAllNonAtomicFailure` for the same ordering note).
        mock.enqueueError(ValidationError(message: "bad batch"))
        mock.enqueue(edgeBatch(count: 2))
        mock.enqueue(edgeBatch(count: 1))

        let input = (0..<5).map { i in
            BulkEdgeInputItem(
                sourceId: "src-\(i)",
                targetId: "tgt-\(i)",
                edgeType: "about"
            )
        }
        let result = try await client.edges.bulkAll(input, batchSize: 2, atomic: false)

        #expect(result.counts.created == 3)
        #expect(result.counts.errored == 2)
        #expect(result.results.count == 5)
        #expect(result.results[0].outcome == .errored)
        #expect(result.results[1].outcome == .errored)
        #expect(result.results[2].outcome == .created)
        #expect(result.results[3].outcome == .created)
        #expect(result.results[4].outcome == .created)
    }
}

// MARK: - Helpers

/// Thread-safe recorder for `progressHandler` invocations. The handler
/// is `@Sendable` and may be called off any executor — a plain `var`
/// would trip strict-concurrency checks.
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int, Int)] = []

    func record(completed: Int, total: Int) {
        lock.withLock { items.append((completed, total)) }
    }

    func snapshot() -> [(Int, Int)] {
        lock.withLock { items }
    }
}
