import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

@Suite("ItemsNamespace — bulk + bulkAction")
struct BulkTests {

    func makeClient() -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let client = MarfaClient(configuration: config, transport: mock)
        return (client, mock)
    }

    func sampleBulkResult() -> BulkResult {
        BulkResult(
            counts: BulkResultCounts(created: 1, updated: 0, skipped: 0, errored: 0),
            results: [
                BulkResultEntry(
                    index: 0, outcome: .created, id: "itm_abc", reason: nil, error: nil
                )
            ],
            blobsImported: nil
        )
    }

    func sampleBulkActionResult(action: String) -> BulkActionResult {
        BulkActionResult(
            action: action,
            matched: 3,
            succeeded: 3,
            errored: 0,
            dryRun: false,
            ids: nil,
            errors: nil,
            blobHashesReferenced: action == "purge" ? 0 : nil
        )
    }

    /// Sample queued envelope returned by `POST /items/bulk-actions`
    /// (status 202). The SDK polls until terminal.
    func sampleQueuedJob(action: String, id: String = "baj_test") -> BulkActionJob {
        BulkActionJob(
            id: id,
            action: action,
            status: .queued,
            matched: 3,
            processed: 0,
            succeeded: 0,
            errored: 0,
            startedAt: nil,
            finishedAt: nil,
            error: nil,
            result: nil
        )
    }

    /// Sample completed envelope — the result the polling loop resolves with.
    func sampleCompletedJob(action: String, id: String = "baj_test") -> BulkActionJob {
        BulkActionJob(
            id: id,
            action: action,
            status: .completed,
            matched: 3,
            processed: 3,
            succeeded: 3,
            errored: 0,
            startedAt: "2026-05-20T20:00:00.000Z",
            finishedAt: "2026-05-20T20:00:01.000Z",
            error: nil,
            result: sampleBulkActionResult(action: action)
        )
    }

    /// Encode + raw-enqueue a BulkActionJob as the 202 POST response.
    func enqueueQueued(_ mock: MockTransport, job: BulkActionJob) {
        let data = try! JSONEncoder().encode(job)
        mock.enqueueRaw(data: data, statusCode: 202)
    }

    // MARK: - bulk

    @Test("bulk sends POST /items/bulk with BulkInput body")
    func bulkPostsExpectedBody() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(sampleBulkResult())

        let input = BulkInput(
            items: [
                BulkItemInput(
                    type: "core.note",
                    properties: ["title": .string("one")],
                    sourceId: "s1"
                )
            ],
            mode: .upsert,
            atomic: true
        )
        let result = try await client.items.bulk(input)

        #expect(result.counts.created == 1)
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/items/bulk")
    }

    @Test("bulk encodes mode as snake_case value (create_only)")
    func bulkModeCreateOnlyEncodesAsSnakeCase() throws {
        let input = BulkInput(
            items: [BulkItemInput(type: "core.note")],
            mode: .createOnly
        )
        let data = try JSONEncoder().encode(input)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"mode\":\"create_only\""))
    }

    @Test("bulk snake-cases field names on the wire")
    func bulkEncodesSnakeCaseFields() throws {
        let input = BulkInput(
            items: [
                BulkItemInput(type: "core.note", sourceId: "abc")
            ],
            emitEvents: true
        )
        let data = try JSONEncoder().encode(input)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"source_id\":\"abc\""))
        #expect(json.contains("\"emit_events\":true"))
    }

    // MARK: - bulkAction

    @Test("bulkAction transition posts to /items/bulk-actions, polls to terminal")
    func bulkActionTransitionPath() async throws {
        let (client, mock) = makeClient()
        // POST returns 202 + queued envelope; SDK then polls
        // GET /items/bulk-actions/jobs/:id and resolves with the
        // embedded BulkActionResult.
        enqueueQueued(mock, job: sampleQueuedJob(action: "transition"))
        mock.enqueue(sampleCompletedJob(action: "transition"))

        let input = BulkActionInput.transition(
            filter: BulkActionFilter(tags: ["x"]),
            state: .archived
        )
        let result = try await client.items.bulkAction(
            input,
            options: BulkActionPollOptions(pollIntervalMs: 1)
        )

        #expect(result.action == "transition")
        #expect(result.succeeded == 3)
        #expect(mock.calls.count == 2)
        #expect(mock.calls[0].path == "/items/bulk-actions")
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[1].path == "/items/bulk-actions/jobs/baj_test")
        #expect(mock.calls[1].method == .get)
    }

    // MARK: - Async job lifecycle

    @Test("bulkAction polls through queued → in_progress → completed")
    func bulkActionPollsThroughIntermediateStates() async throws {
        let (client, mock) = makeClient()
        enqueueQueued(mock, job: sampleQueuedJob(action: "update_tier"))
        // First poll: in_progress
        let inProgress = BulkActionJob(
            id: "baj_test", action: "update_tier", status: .inProgress,
            matched: 3, processed: 1, succeeded: 1, errored: 0,
            startedAt: "2026-05-20T20:00:00Z", finishedAt: nil,
            error: nil, result: nil
        )
        mock.enqueue(inProgress)
        // Second poll: completed
        mock.enqueue(sampleCompletedJob(action: "update_tier"))

        // Swift 6 strict concurrency: onProgress runs in a Sendable
        // closure, so we capture via a lock-guarded class.
        final class TickCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func tick() { lock.lock(); n += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let ticks = TickCounter()
        let result = try await client.items.bulkAction(
            BulkActionInput.updateTier(filter: BulkActionFilter(tags: ["x"]), tier: .feed),
            options: BulkActionPollOptions(pollIntervalMs: 1, onProgress: { _ in ticks.tick() })
        )

        #expect(result.action == "update_tier")
        #expect(ticks.count == 1)
        #expect(mock.calls.count == 3)
    }

    @Test("bulkAction throws BulkJobCancelledError when status is cancelled")
    func bulkActionThrowsOnCancelled() async throws {
        let (client, mock) = makeClient()
        enqueueQueued(mock, job: sampleQueuedJob(action: "purge"))
        let cancelled = BulkActionJob(
            id: "baj_test", action: "purge", status: .cancelled,
            matched: 3, processed: 1, succeeded: 1, errored: 0,
            startedAt: "2026-05-20T20:00:00Z", finishedAt: "2026-05-20T20:00:00.5Z",
            error: nil, result: nil
        )
        mock.enqueue(cancelled)

        do {
            _ = try await client.items.bulkAction(
                BulkActionInput.purge(filter: BulkActionFilter(tags: ["x"]), options: .init(confirm: "PURGE")),
                options: BulkActionPollOptions(pollIntervalMs: 1)
            )
            Issue.record("Expected BulkJobCancelledError")
        } catch let err as BulkJobCancelledError {
            #expect(err.jobId == "baj_test")
            #expect(err.processed == 1)
        }
    }

    @Test("bulkAction throws BulkJobFailedError when status is failed")
    func bulkActionThrowsOnFailed() async throws {
        let (client, mock) = makeClient()
        enqueueQueued(mock, job: sampleQueuedJob(action: "transition"))
        let failed = BulkActionJob(
            id: "baj_test", action: "transition", status: .failed,
            matched: 3, processed: 1, succeeded: 0, errored: 1,
            startedAt: "2026-05-20T20:00:00Z", finishedAt: "2026-05-20T20:00:00.5Z",
            error: "Storage exception during chunk 2",
            result: nil
        )
        mock.enqueue(failed)

        do {
            _ = try await client.items.bulkAction(
                BulkActionInput.transition(filter: BulkActionFilter(tags: ["x"]), state: .archived),
                options: BulkActionPollOptions(pollIntervalMs: 1)
            )
            Issue.record("Expected BulkJobFailedError")
        } catch let err as BulkJobFailedError {
            #expect(err.jobId == "baj_test")
            #expect(err.reason.contains("chunk 2"))
        }
    }

    @Test("bulkActionAsync returns the queued envelope without polling")
    func bulkActionAsyncSurfacesQueuedEnvelope() async throws {
        let (client, mock) = makeClient()
        enqueueQueued(mock, job: sampleQueuedJob(action: "transition", id: "baj_async"))

        let job = try await client.items.bulkActionAsync(
            BulkActionInput.transition(filter: BulkActionFilter(tags: ["x"]), state: .archived)
        )

        #expect(job.id == "baj_async")
        #expect(job.status == .queued)
        #expect(mock.calls.count == 1)
    }

    @Test("bulkActionStatus and bulkActionCancel hit the jobs endpoint")
    func bulkActionStatusAndCancel() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(sampleCompletedJob(action: "transition", id: "baj_x"))
        mock.enqueue(sampleCompletedJob(action: "transition", id: "baj_x"))

        let status = try await client.items.bulkActionStatus(jobId: "baj_x")
        #expect(status.id == "baj_x")
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/items/bulk-actions/jobs/baj_x")

        let cancelled = try await client.items.bulkActionCancel(jobId: "baj_x")
        #expect(cancelled.id == "baj_x")
        #expect(mock.calls[1].method == .delete)
        #expect(mock.calls[1].path == "/items/bulk-actions/jobs/baj_x")
    }

    @Test("bulkAction dry_run path stays synchronous (status 200)")
    func bulkActionDryRunStaysSynchronous() async throws {
        let (client, mock) = makeClient()
        let dryRunResult = BulkActionResult(
            action: "transition", matched: 3, succeeded: 0, errored: 0,
            dryRun: true, ids: ["a", "b", "c"], errors: nil,
            blobHashesReferenced: nil
        )
        let data = try JSONEncoder().encode(dryRunResult)
        mock.enqueueRaw(data: data, statusCode: 200)

        let result = try await client.items.bulkAction(
            BulkActionInput.transition(
                filter: BulkActionFilter(tags: ["x"]),
                state: .archived,
                options: .init(dryRun: true)
            ),
            options: BulkActionPollOptions(pollIntervalMs: 1)
        )

        #expect(result.dryRun == true)
        #expect(result.ids == ["a", "b", "c"])
        #expect(mock.calls.count == 1)
    }

    @Test("bulkAction encodes discriminator + params for each verb")
    func bulkActionDiscriminatorEncoding() throws {
        let encoder = JSONEncoder()

        let transition = try encoder.encode(BulkActionInput.transition(
            filter: BulkActionFilter(tags: ["t"]), state: .trashed
        ))
        #expect(String(data: transition, encoding: .utf8)!.contains("\"action\":\"transition\""))
        #expect(String(data: transition, encoding: .utf8)!.contains("\"state\":\"trashed\""))

        let updateTier = try encoder.encode(BulkActionInput.updateTier(
            filter: BulkActionFilter(type: "core.note"), tier: .feed
        ))
        let libJson = String(data: updateTier, encoding: .utf8)!
        #expect(libJson.contains("\"action\":\"update_tier\""))
        #expect(libJson.contains("\"tier\":\"feed\""))

        let updateTimestamp = try encoder.encode(BulkActionInput.updateTimestamp(
            filter: BulkActionFilter(), timestamp: "2020-01-01T00:00:00Z"
        ))
        let tsJson = String(data: updateTimestamp, encoding: .utf8)!
        #expect(tsJson.contains("\"action\":\"update_timestamp\""))
        #expect(tsJson.contains("\"timestamp\":\"2020-01-01T00:00:00Z\""))

        let updateTags = try encoder.encode(BulkActionInput.updateTags(
            filter: BulkActionFilter(), add: ["a"], remove: ["b"]
        ))
        let tagsJson = String(data: updateTags, encoding: .utf8)!
        #expect(tagsJson.contains("\"action\":\"update_tags\""))
        #expect(tagsJson.contains("\"add\":[\"a\"]"))
        #expect(tagsJson.contains("\"remove\":[\"b\"]"))

        let updateProperties = try encoder.encode(BulkActionInput.updateProperties(
            filter: BulkActionFilter(), patch: ["k": .string("v")]
        ))
        let propJson = String(data: updateProperties, encoding: .utf8)!
        #expect(propJson.contains("\"action\":\"update_properties\""))
        #expect(propJson.contains("\"patch\":{\"k\":\"v\"}"))
    }

    @Test("bulkAction purge refuses to encode without confirm = PURGE")
    func bulkActionPurgeGuardsConfirm() {
        let input = BulkActionInput.purge(
            filter: BulkActionFilter(type: "core.note"),
            options: BulkActionOptions()
        )
        #expect(throws: (any Error).self) {
            _ = try JSONEncoder().encode(input)
        }
    }

    @Test("bulkAction purge encodes confirm literal when supplied")
    func bulkActionPurgeWithConfirm() throws {
        let input = BulkActionInput.purge(
            filter: BulkActionFilter(type: "core.note"),
            options: BulkActionOptions(confirm: "PURGE")
        )
        let data = try JSONEncoder().encode(input)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"action\":\"purge\""))
        #expect(json.contains("\"confirm\":\"PURGE\""))
    }

    @Test("bulkAction encodes dry_run + max_items as snake_case")
    func bulkActionOptionsEncoding() throws {
        let input = BulkActionInput.transition(
            filter: BulkActionFilter(),
            state: .archived,
            options: BulkActionOptions(dryRun: true, maxItems: 100, emitEvents: true)
        )
        let data = try JSONEncoder().encode(input)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"dry_run\":true"))
        #expect(json.contains("\"max_items\":100"))
        #expect(json.contains("\"emit_events\":true"))
    }

    @Test("bulkAction round-trips through JSON (replay-queue shape)")
    func bulkActionRoundTrip() throws {
        // SyncEngine replay decodes the payload from the mutation queue;
        // this proves the BulkActionInput Decodable impl agrees with the
        // Encodable impl. Assert the `action` discriminator survives
        // the round-trip for every case — encoded byte equality is too
        // strict because JSONEncoder key ordering isn't stable across
        // calls.
        let cases: [(BulkActionInput, String)] = [
            (.transition(filter: BulkActionFilter(type: "core.note"), state: .archived), "transition"),
            (.purge(filter: BulkActionFilter(tags: ["dead"]), options: BulkActionOptions(confirm: "PURGE")), "purge"),
            (.updateTags(filter: BulkActionFilter(), add: ["x"], remove: nil), "update_tags"),
            (.updateTier(filter: BulkActionFilter(), tier: .library), "update_tier"),
            (.updateProperties(filter: BulkActionFilter(), patch: ["k": .int(42)]), "update_properties"),
            (.updateTimestamp(filter: BulkActionFilter(), timestamp: "2024-01-01T00:00:00Z"), "update_timestamp"),
        ]
        for (input, expectedAction) in cases {
            let data = try JSONEncoder().encode(input)
            let decoded = try JSONDecoder().decode(BulkActionInput.self, from: data)
            // Destructure via encode path — re-encode must still contain
            // the same discriminator.
            let reencoded = try JSONEncoder().encode(decoded)
            let reJson = String(data: reencoded, encoding: .utf8)!
            #expect(reJson.contains("\"action\":\"\(expectedAction)\""))
        }
    }

    @Test("Bulk server errors surface as typed errors")
    func bulkAtomicRollbackErrorSurfaces() async throws {
        let (client, mock) = makeClient()
        mock.enqueueError(ValidationError(message: "bulk_atomic_rollback"))

        await #expect(throws: ValidationError.self) {
            _ = try await client.items.bulk(
                BulkInput(items: [BulkItemInput(type: "core.note")])
            )
        }
    }
}
