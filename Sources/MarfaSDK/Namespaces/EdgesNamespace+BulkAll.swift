import Foundation

// MARK: - edges.bulkAll — chunked iteration over /edges/bulk

public extension EdgesNamespace {

    /// Creates or upserts many edges by chunking through ``bulk(_:)`` in
    /// batches. Aggregates per-edge results across batches into a single
    /// ``BulkEdgeResult`` with absolute indices preserved.
    ///
    /// Same batching shape as ``ItemsNamespace/bulkAll(_:batchSize:mode:atomic:emitEvents:progressHandler:)`` —
    /// the server caps `/edges/bulk` at 5000 edges per call; `bulkAll`
    /// exists so mode-transition flows on larger spaces don't need to
    /// reinvent batch iteration.
    ///
    /// Cross-batch atomicity does NOT hold. Each batch's `atomic`
    /// guarantee stops at its own transaction — if batch 2 errors, batch
    /// 1's writes have already committed. Default `atomic: false`
    /// collects errors per batch and keeps iterating.
    ///
    /// - Parameters:
    ///   - edges: Full edge set to bulk-write. Order preserved end-to-end.
    ///   - batchSize: Edges per underlying ``bulk(_:)`` call. Default
    ///     `500`, clamped to the server's 5000 cap.
    ///   - mode: ``BulkMode`` passed to every batch. Default ``BulkMode/upsert``.
    ///   - atomic: Per-batch atomicity flag. Default `false`.
    ///   - emitEvents: Per-batch opt-in for `edge_created` webhook fanout.
    ///     Default `false`.
    ///   - progressHandler: Fires after each batch with
    ///     `(edgesCompleted, edgesTotal)`.
    /// - Returns: Aggregate ``BulkEdgeResult`` across every batch.
    func bulkAll(
        _ edges: [BulkEdgeInputItem],
        batchSize: Int = 500,
        mode: BulkMode = .upsert,
        atomic: Bool = false,
        emitEvents: Bool = false,
        progressHandler: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> BulkEdgeResult {
        let total = edges.count
        guard total > 0 else {
            return BulkEdgeResult(
                counts: BulkResultCounts(
                    created: 0, updated: 0, skipped: 0, errored: 0
                ),
                results: []
            )
        }

        let capped = max(1, min(batchSize, 5000))
        var aggCreated = 0
        var aggUpdated = 0
        var aggSkipped = 0
        var aggErrored = 0
        var aggResults: [BulkEdgeResultEntry] = []
        aggResults.reserveCapacity(total)

        var processed = 0
        var offset = 0
        while offset < total {
            let end = min(offset + capped, total)
            let slice = Array(edges[offset..<end])
            let input = BulkEdgeInput(
                edges: slice,
                mode: mode,
                atomic: atomic,
                emitEvents: emitEvents
            )

            do {
                let result = try await bulk(input)
                aggCreated += result.counts.created
                aggUpdated += result.counts.updated
                aggSkipped += result.counts.skipped
                aggErrored += result.counts.errored
                for entry in result.results {
                    aggResults.append(BulkEdgeResultEntry(
                        index: offset + entry.index,
                        outcome: entry.outcome,
                        id: entry.id,
                        reason: entry.reason,
                        error: entry.error
                    ))
                }
            } catch {
                if atomic {
                    throw error
                }
                let message = String(describing: error)
                for local in 0..<slice.count {
                    aggResults.append(BulkEdgeResultEntry(
                        index: offset + local,
                        outcome: .errored,
                        error: BulkResultError(
                            code: "batch_error",
                            message: message
                        )
                    ))
                }
                aggErrored += slice.count
            }

            processed = end
            offset = end
            progressHandler?(processed, total)
        }

        return BulkEdgeResult(
            counts: BulkResultCounts(
                created: aggCreated,
                updated: aggUpdated,
                skipped: aggSkipped,
                errored: aggErrored
            ),
            results: aggResults
        )
    }
}
