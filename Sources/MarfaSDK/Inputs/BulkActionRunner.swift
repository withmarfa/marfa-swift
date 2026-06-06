import Foundation

/// Poll knobs accepted by ``ItemsNamespace/bulkAction(_:options:)``.
///
/// Defaults: 250ms initial interval, doubling to 2s ceiling, 30-minute
/// total wall-clock budget. Tests typically supply tight intervals
/// (`init(pollIntervalMs: 25)`) so jobs settle quickly.
public struct BulkActionPollOptions: Sendable {
    public let pollIntervalMs: Int
    public let maxPollIntervalMs: Int
    public let maxWaitMs: Int
    public let onProgress: (@Sendable (BulkActionJob) -> Void)?

    public init(
        pollIntervalMs: Int = 250,
        maxPollIntervalMs: Int = 2_000,
        maxWaitMs: Int = 30 * 60_000,
        onProgress: (@Sendable (BulkActionJob) -> Void)? = nil
    ) {
        self.pollIntervalMs = pollIntervalMs
        self.maxPollIntervalMs = maxPollIntervalMs
        self.maxWaitMs = maxWaitMs
        self.onProgress = onProgress
    }

    public static let `default` = BulkActionPollOptions()
}

/// Shared remote runner used by both ``ItemsNamespace/bulkAction(_:options:)``
/// and the synced-mode mutation-queue replay path in ``SyncEngine``. POSTs
/// the input, distinguishes the 200 (dry-run) and 202 (queued) responses, and
/// polls a queued job through to a terminal state.
///
/// Kept namespace-independent so the synced-mode replayer doesn't have
/// to hold a reference to ``ItemsNamespace``.
enum BulkActionRunner {

    /// Initial response from `POST /items/bulk-actions`.
    ///
    /// - ``inline(_:)``: server returned 200 with an inline
    ///   ``BulkActionResult`` (dry-run path).
    /// - ``queued(_:)``: server returned 202 with a
    ///   ``BulkActionJob`` envelope; caller drives polling via
    ///   ``pollUntilTerminal(transport:jobId:options:)``.
    enum InitialResponse {
        case inline(BulkActionResult)
        case queued(BulkActionJob)
    }

    /// POST the input. Returns one of the two response variants
    /// depending on the server's status code. Throws a typed
    /// ``MarfaError`` on a non-2xx response, decoding the standard
    /// `{ error: { code, message } }` shape.
    static func post(
        transport: Transport,
        input: BulkActionInput
    ) async throws -> InitialResponse {
        let bodyData = try JSONEncoder().encode(input)
        let (data, response) = try await transport.rawRequest(
            method: .post,
            path: "/items/bulk-actions",
            body: bodyData,
            contentType: "application/json",
            query: nil
        )
        let status = response.statusCode
        if !(200...299).contains(status) {
            throw try decodeErrorResponse(data: data, status: status)
        }
        let decoder = JSONDecoder()
        if status == 200 {
            return .inline(try decoder.decode(BulkActionResult.self, from: data))
        }
        // 202 (and any future 2xx variant) — async job envelope.
        return .queued(try decoder.decode(BulkActionJob.self, from: data))
    }

    /// Poll `GET /items/bulk-actions/jobs/:id` until the row reaches a
    /// terminal state (`completed` / `failed` / `cancelled`).
    /// Exponential backoff from `pollIntervalMs` to `maxPollIntervalMs`;
    /// throws ``MarfaError`` with `code: "poll_timeout"` past
    /// `maxWaitMs`.
    static func pollUntilTerminal(
        transport: Transport,
        jobId: String,
        options: BulkActionPollOptions
    ) async throws -> BulkActionJob {
        let start = Date()
        var intervalMs = options.pollIntervalMs

        while true {
            let job: BulkActionJob = try await transport.request(
                method: .get,
                path: "/items/bulk-actions/jobs/\(jobId)",
                body: nil,
                query: nil
            )
            switch job.status {
            case .completed, .failed, .cancelled:
                return job
            case .queued, .inProgress:
                options.onProgress?(job)
            }

            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            if elapsedMs >= options.maxWaitMs {
                throw MarfaError(
                    code: "poll_timeout",
                    message: "Bulk action job \(jobId) did not terminate within \(options.maxWaitMs)ms",
                    status: 0
                )
            }

            let sleepMs = min(intervalMs, options.maxWaitMs - elapsedMs)
            try await Task.sleep(nanoseconds: UInt64(sleepMs) * 1_000_000)
            intervalMs = min(intervalMs * 2, options.maxPollIntervalMs)
        }
    }

    /// Single-shot: POST → (200 returns result; 202 polls to terminal).
    /// Resolves with the embedded ``BulkActionResult`` on a successful
    /// completion; throws ``BulkJobCancelledError`` or
    /// ``BulkJobFailedError`` for non-completed terminals.
    static func runToCompletion(
        transport: Transport,
        input: BulkActionInput,
        options: BulkActionPollOptions = .default
    ) async throws -> BulkActionResult {
        switch try await post(transport: transport, input: input) {
        case .inline(let result):
            return result
        case .queued(let queued):
            let final = try await pollUntilTerminal(
                transport: transport,
                jobId: queued.id,
                options: options
            )
            switch final.status {
            case .completed:
                guard let r = final.result else {
                    throw MarfaError(
                        code: "internal_error",
                        message: "Bulk action job \(final.id) reported completed but carried no result envelope",
                        status: 0
                    )
                }
                return r
            case .cancelled:
                throw BulkJobCancelledError(
                    jobId: final.id,
                    processed: final.processed,
                    succeeded: final.succeeded,
                    errored: final.errored
                )
            case .failed:
                throw BulkJobFailedError(
                    jobId: final.id,
                    reason: final.error ?? "Unknown error"
                )
            case .queued, .inProgress:
                throw MarfaError(
                    code: "internal_error",
                    message: "Bulk action job \(final.id) returned non-terminal status from pollUntilTerminal",
                    status: 0
                )
            }
        }
    }

    private static func decodeErrorResponse(data: Data, status: Int) throws -> MarfaError {
        struct Body: Decodable {
            struct Inner: Decodable {
                let code: String
                let message: String
            }
            let error: Inner
        }
        if let body = try? JSONDecoder().decode(Body.self, from: data) {
            return MarfaError(
                code: body.error.code,
                message: body.error.message,
                status: status
            )
        }
        return MarfaError(
            code: "http_error",
            message: "HTTP \(status)",
            status: status
        )
    }
}

/// The async bulk_action job reached `status: .cancelled`. The envelope
/// carries partial counts so callers know how far the worker got before
/// observing the cancel signal.
public struct BulkJobCancelledError: Error, Sendable {
    public let jobId: String
    public let processed: Int
    public let succeeded: Int
    public let errored: Int
}

/// The async bulk_action job reached `status: .failed`. The worker hit an
/// unrecoverable error (typically a storage-level problem); `reason` carries
/// the underlying message.
public struct BulkJobFailedError: Error, Sendable {
    public let jobId: String
    public let reason: String
}
