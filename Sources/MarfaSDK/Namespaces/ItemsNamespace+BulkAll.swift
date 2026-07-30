import Foundation

// MARK: - items.bulkAll — chunked iteration over /items/bulk

public extension ItemsNamespace {

    /// Creates or upserts many items by chunking through ``bulk(_:)`` in
    /// batches. Aggregates per-item results across batches into a single
    /// ``BulkResult`` with absolute indices preserved.
    ///
    /// The server caps `/items/bulk` at 5000 items per call. `bulkAll`
    /// exists so callers don't have to reinvent batch-iteration for
    /// migrations or imports larger than the cap — common in
    /// mode-transition flows (Local → Marfa, iCloud → Marfa) on
    /// larger spaces.
    ///
    /// Failure model mirrors ``bulk(_:)`` with the same `atomic` flag
    /// passed through:
    /// - `atomic: true` — any batch that throws aborts `bulkAll`; results
    ///   from preceding batches are lost to the caller. Use for strict
    ///   all-or-nothing semantics at the single-batch scale, accepting
    ///   that partial server-side writes ARE possible across batch
    ///   boundaries (each batch's atomic guarantee stops at its own
    ///   transaction; there is no cross-batch transaction).
    /// - `atomic: false` (default here) — per-batch errors land in the
    ///   aggregate `errored` count and a single synthetic
    ///   ``BulkResultEntry`` per failed batch, then iteration
    ///   continues. Best-effort ingest.
    ///
    /// `progressHandler` fires on the task's current executor after each
    /// completed batch with `(itemsCompleted, itemsTotal)` — useful for
    /// wiring progress UI on top of an otherwise opaque bulk call.
    ///
    /// - Parameters:
    ///   - items: The full set of items to bulk-write. Split client-side;
    ///     order preserved end-to-end.
    ///   - batchSize: Items per underlying ``bulk(_:)`` call. Default
    ///     `500`. Capped at the server's 5000 per-call limit — larger
    ///     values clamp down.
    ///   - mode: ``BulkMode`` passed to every batch. Default ``BulkMode/upsert``.
    ///   - atomic: Per-batch atomicity flag. Default `false` so inter-batch
    ///     partial failures don't abort the whole run.
    ///   - emitEvents: Per-batch opt-in for item webhook fanout. Default `false`.
    ///   - progressHandler: Called after each batch with
    ///     `(itemsCompleted, itemsTotal)`. `@Sendable` because the handler
    ///     may cross executors.
    /// - Returns: Aggregate ``BulkResult`` with unified counts and
    ///   per-item entries across every batch.
    func bulkAll(
        _ items: [BulkItemInput],
        batchSize: Int = 500,
        mode: BulkMode = .upsert,
        atomic: Bool = false,
        emitEvents: Bool = false,
        progressHandler: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> BulkResult {
        let total = items.count
        guard total > 0 else {
            return BulkResult(
                counts: BulkResultCounts(
                    created: 0, updated: 0, skipped: 0, errored: 0
                ),
                results: [],
                blobsImported: nil
            )
        }

        let capped = max(1, min(batchSize, 5000))
        var aggCreated = 0
        var aggUpdated = 0
        var aggSkipped = 0
        var aggErrored = 0
        var aggResults: [BulkResultEntry] = []
        aggResults.reserveCapacity(total)

        var processed = 0
        var offset = 0
        while offset < total {
            let end = min(offset + capped, total)
            let slice = Array(items[offset..<end])
            let input = BulkInput(
                items: slice,
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
                    aggResults.append(BulkResultEntry(
                        index: offset + entry.index,
                        outcome: entry.outcome,
                        id: entry.id,
                        reason: entry.reason,
                        error: entry.error
                    ))
                }
            } catch {
                if atomic {
                    // Atomic callers explicitly asked for throw-on-error;
                    // propagate the underlying failure with the caller's
                    // slice context preserved in `index`.
                    throw error
                }
                // Non-atomic — synthesize one errored entry per item in
                // the failed slice so counts stay consistent with the
                // total input size.
                let message = String(describing: error)
                for local in 0..<slice.count {
                    aggResults.append(BulkResultEntry(
                        index: offset + local,
                        outcome: .errored,
                        id: nil,
                        reason: nil,
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

        return BulkResult(
            counts: BulkResultCounts(
                created: aggCreated,
                updated: aggUpdated,
                skipped: aggSkipped,
                errored: aggErrored
            ),
            results: aggResults,
            blobsImported: nil
        )
    }
}
