import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// What a synced client does with the answer a bulk page comes back with.
///
/// A bulk page is one queue record carrying many writes, and the server
/// answers each of them separately. The replay used to discard that answer
/// entirely, which made the two halves below invisible: an entry the server
/// refused, and an id it named differently from the one the device sent.
///
/// Every test drives the drain through `triggerProactiveDrainForTesting`,
/// which awaits the replay to completion, so a failure is an expectation
/// about the queue rather than a timeout that could equally mean a busy
/// machine.
@Suite("A bulk replay reads its result", .timeLimit(.minutes(1)))
struct SyncEngineBulkResultTests {

    private func fixture() async throws -> (
        LocalStore, MutationQueue, ItemMintingTransport, ConnectionStateManager, SyncEngine
    ) {
        let (store, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        try await SyncEngineTestKit.markImported(queue)
        let transport = ItemMintingTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        return (store, queue, transport, connManager, engine)
    }

    private func page(
        _ entries: [(id: String, type: String)],
        atomic: Bool,
        mode: BulkMode? = nil
    ) -> BulkInput {
        BulkInput(
            items: entries.map { BulkItemInput(id: $0.id, type: $0.type) },
            mode: mode,
            atomic: atomic,
            enableFanout: nil
        )
    }

    private func drops(from engine: SyncEngine) async -> Task<[SyncEvent], Never> {
        let events = await engine.events
        return Task {
            var out: [SyncEvent] = []
            for await event in events {
                out.append(event)
                if case .synced = event { return out }
                if case .failed = event { return out }
            }
            return out
        }
    }

    // MARK: - A refused entry

    @Test("an entry the server refuses is dead-lettered with its code, not discarded")
    func refusedEntryIsDeadLettered() async throws {
        let (_, queue, transport, connManager, engine) = try await fixture()
        await transport.refuse(type: "core.bad", code: "invalid_type", message: "Invalid type identifier")

        let good = "01c00000-0000-7000-8000-00000000000a"
        let bad = "01c00000-0000-7000-8000-00000000000b"
        try await queue.enqueueBulk(
            page([(good, "core.note"), (bad, "core.bad")], atomic: false)
        )

        let collector = await drops(from: engine)
        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // The page reached the server and is finished, so the record retires.
        #expect(try await queue.isEmpty)

        // The refused entry is in the dead-letter log under the server's own
        // code, keyed apart from the page so it cannot collapse against a
        // sibling refusal.
        let dropped = try await queue.fetchDropped()
        #expect(dropped.count == 1)
        let entry = try #require(dropped.first)
        #expect(entry.kind == .bulk)
        #expect(entry.localId == bad)
        #expect(entry.errorCode == "invalid_type")
        // The call answered 200; this entry's refusal never had a status of
        // its own, and 0 is what the column reserves for that.
        #expect(entry.errorStatus == 0)
        // The refused entry alone, not the page it traveled in.
        let payload = try #require(entry.payloadJson.data(using: .utf8))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        #expect(decoded["id"] as? String == bad)
        #expect(decoded["type"] as? String == "core.bad")
        #expect(decoded["items"] == nil, "the whole page was kept, not the entry")

        let collected = await collector.value
        let events = collected.compactMap { event -> String? in
            if case let .mutationDropped(kind, itemId, _, _) = event { return "\(kind):\(itemId ?? "-")" }
            return nil
        }
        #expect(events == ["bulk:\(bad)"])
    }

    @Test("a page where every entry is refused is not a silent success")
    func allErroredPageIsNotSilent() async throws {
        let (_, queue, transport, connManager, engine) = try await fixture()
        await transport.refuse(type: "core.bad", code: "invalid_type")

        let ids = [
            "01c00000-0000-7000-8000-00000000001a",
            "01c00000-0000-7000-8000-00000000001b",
        ]
        try await queue.enqueueBulk(
            page(ids.map { ($0, "core.bad") }, atomic: false)
        )

        let collector = await drops(from: engine)
        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // The queue emptying is what it always did. The dead-letter rows are
        // the part that was missing: before this, the whole page vanished
        // reporting success and an app had nothing to show for the writes.
        #expect(try await queue.isEmpty)
        let dropped = try await queue.fetchDropped()
        #expect(dropped.count == 2)
        #expect(Set(dropped.map(\.localId)) == Set(ids.map { Optional($0) }))
        // One row per entry rather than two rows sharing the page's id, which
        // would collapse in any list keyed on it.
        #expect(Set(dropped.map(\.id)).count == 2)

        let collected = await collector.value
        let count = collected.filter { if case .mutationDropped = $0 { return true } else { return false } }.count
        #expect(count == 2)
    }

    // MARK: - The atomic rollback

    @Test("an atomic page rolled back on a content refusal is dropped with that code")
    func atomicRollbackOnPermanentCodeDrops() async throws {
        let (_, queue, transport, connManager, engine) = try await fixture()
        await transport.refuse(type: "core.bad", code: "invalid_type", message: "Invalid type identifier")

        try await queue.enqueueBulk(
            page([
                ("01c00000-0000-7000-8000-00000000002a", "core.note"),
                ("01c00000-0000-7000-8000-00000000002b", "core.bad"),
            ], atomic: true)
        )

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // Every rollback is final, and nothing was written: the route rolls
        // back only on a validation-class refusal of one entry's content, and
        // repeating the page produces the same refusal. The codes worth
        // retrying cannot reach here — quota is reserved by a path this route
        // does not call, rate limits and a suspended space are refused by
        // middleware ahead of it, and a version conflict needs a version the
        // bulk update never sends.
        #expect(try await queue.isEmpty)
        let entry = try #require(try await queue.fetchDropped().first)
        // The refusal, not the wrapper that delivered it. `bulk_atomic_rollback`
        // says something was refused and never which thing — and it only
        // survives the transport at all because a 400 keeps the code the
        // server sent.
        #expect(entry.errorCode == "invalid_type")
        #expect(entry.errorStatus == 400)
    }

    // MARK: - Outcomes that are not failures

    @Test("an id the server resolves to a different row is left alone, not dropped")
    func divergentIdIsNotTreatedAsAFailure() async throws {
        let (store, queue, transport, connManager, engine) = try await fixture()

        // An upsert resolving `(source, source_id)` answers with the id of
        // the row it matched, which is not the id the page carried. The
        // double has to actually answer a different one or the assertion
        // below would hold just as well against a client that repaired it.
        let deviceId = "01c00000-0000-7000-8000-00000000004a"
        let serverId = "01c00000-0000-7000-8000-0000000004ff"
        await transport.resolve(deviceId, to: serverId)
        try await store.upsertItem(Item(
            createdAt: "2026-09-02T00:00:00.000Z", id: deviceId,
            properties: [:], schemaVersion: 1, source: "test", state: .active,
            tier: .feed, timestamp: "2026-09-02T00:00:00.000Z", type: "core.note",
            updatedAt: "2026-09-02T00:00:00.000Z", version: 1
        ))
        try await queue.enqueueBulk(page([(deviceId, "core.note")], atomic: false))

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // `updated` is a success. The row stays where the device wrote it —
        // the answer carries an id and not a row, so there is nothing to
        // adopt and nothing here invents one.
        #expect(try await queue.isEmpty)
        #expect(try await queue.fetchDropped().isEmpty)
        // Untouched: the row stays under the id the device wrote it, and no
        // row appears under the server's. The answer carries an id and not a
        // row, so there is nothing here to adopt and nothing invents one.
        #expect(try await store.fetchItem(id: deviceId).id == deviceId)
        #expect((try? await store.fetchItem(id: serverId)) == nil)
    }

    @Test("an answer indexed outside the page it was sent is ignored, not misattributed")
    func outOfRangeIndexIsIgnored() async throws {
        let (_, queue, transport, connManager, engine) = try await fixture()
        await transport.answerIndexOffsetForTesting(5)

        try await queue.enqueueBulk(
            page([("01c00000-0000-7000-8000-00000000006a", "core.note")], atomic: false)
        )

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // Nothing to act on and nothing invented: attributing an answer to a
        // guessed entry would put a refusal against the wrong row.
        #expect(try await queue.isEmpty)
        #expect(try await queue.fetchDropped().isEmpty)
    }

    @Test("a create_only page skipping a row it already holds drops nothing")
    func skippedEntryIsNotDropped() async throws {
        let (_, queue, transport, connManager, engine) = try await fixture()

        let existing = "01c00000-0000-7000-8000-00000000005a"
        await transport.hold(existing)
        try await queue.enqueueBulk(
            page([(existing, "core.note")], atomic: false, mode: .createOnly)
        )

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // `skipped` with `duplicate_id` means the row is on the server
        // already. Nothing was written and nothing was lost.
        #expect(try await queue.isEmpty)
        #expect(try await queue.fetchDropped().isEmpty)
    }

    // MARK: - The other two doors

    @Test("a refused edge in a bulk page is dead-lettered under its own edge id")
    func refusedEdgeEntryIsDeadLettered() async throws {
        let (store, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        try await SyncEngineTestKit.markImported(queue)
        let transport = EdgeMintingTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        await transport.refuse(edgeType: "forbidden", code: "edge_permission_denied")

        let goodId = "01d00000-0000-7000-8000-00000000000a"
        let badId = "01d00000-0000-7000-8000-00000000000b"
        try await queue.enqueueBulkEdges(
            BulkEdgeInput(
                edges: [
                    BulkEdgeInputItem(id: goodId, sourceId: "src", targetId: "t1", edgeType: "about"),
                    BulkEdgeInputItem(id: badId, sourceId: "src", targetId: "t2", edgeType: "forbidden"),
                ],
                atomic: false
            )
        )

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        #expect(try await queue.isEmpty)
        let dropped = try await queue.fetchDropped()
        #expect(dropped.count == 1)
        let entry = try #require(dropped.first)
        #expect(entry.kind == .bulkEdges)
        // The edge's own id, not the page's: it is what names the row a
        // person will notice is missing from the graph.
        #expect(entry.localId == badId)
        #expect(entry.errorCode == "edge_permission_denied")
        #expect(entry.errorStatus == 0)
        // The refused edge alone, not the page it traveled in.
        let payload = try #require(entry.payloadJson.data(using: .utf8))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        #expect(decoded["id"] as? String == badId)
        #expect(decoded["edge_type"] as? String == "forbidden")
        #expect(decoded["edges"] == nil, "the whole page was kept, not the entry")
    }

    @Test("items a bulk action could not apply are dead-lettered by id")
    func refusedBulkActionEntriesAreDeadLettered() async throws {
        let (store, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        try await SyncEngineTestKit.markImported(queue)
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )

        try await queue.enqueueBulkAction(
            BulkActionInput.transition(filter: BulkActionFilter(type: "core.note"), state: .archived)
        )

        // A job that matched three items and could not apply two of them.
        // The call succeeds; the entries inside it did not.
        //
        // Staged as the route actually answers a synced replay: a 202 job
        // envelope on `rawRequest`, then the poll that resolves it. The
        // inline-200 fork exists but a replay never reaches it, so a test
        // using it would exercise a path production does not take.
        let refusedA = "01e00000-0000-7000-8000-00000000000a"
        let refusedB = "01e00000-0000-7000-8000-00000000000b"
        let result = BulkActionResult(
            action: "transition", matched: 3, succeeded: 1, errored: 2, dryRun: false,
            ids: nil,
            errors: [
                BulkActionErrorEntry(id: refusedA, code: "invalid_transition", message: "active -> archived refused"),
                BulkActionErrorEntry(id: refusedB, code: "forbidden", message: "type not permitted"),
            ],
            blobHashesReferenced: nil
        )
        let queued = BulkActionJob(
            id: "job-1", action: "transition", status: .queued, matched: 3,
            processed: 0, succeeded: 0, errored: 0, startedAt: nil,
            finishedAt: nil, error: nil, result: nil
        )
        transport.enqueueRaw(data: try JSONEncoder().encode(queued), statusCode: 202)
        transport.enqueue(BulkActionJob(
            id: "job-1", action: "transition", status: .completed, matched: 3,
            processed: 3, succeeded: 1, errored: 2, startedAt: nil,
            finishedAt: nil, error: nil, result: result
        ))

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // Before this, a job that applied none of what it matched was
        // indistinguishable from one that applied all of it.
        #expect(try await queue.isEmpty)
        let dropped = try await queue.fetchDropped()
        #expect(dropped.count == 2)
        #expect(Set(dropped.map(\.localId)) == Set([Optional(refusedA), Optional(refusedB)]))
        #expect(Set(dropped.map(\.errorCode)) == Set(["invalid_transition", "forbidden"]))
        #expect(dropped.allSatisfy { $0.errorStatus == 0 })
        // Keyed by item id, because a filter-driven call has no page to
        // index into and the id is the only thing naming the entry.
        #expect(Set(dropped.map(\.id)).count == 2)
    }

    @Test("the same refused page replayed twice leaves one row per entry")
    func replayingARefusedPageDoesNotDoubleTheLog() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()

        let ids = [
            "01c00000-0000-7000-8000-00000000007a",
            "01c00000-0000-7000-8000-00000000007b",
        ]
        try await queue.enqueueBulk(page(ids.map { ($0, "core.bad") }, atomic: false))
        let record = try #require(try await queue.fetchAll().first)

        let refused = ids.enumerated().map { index, id in
            MutationQueue.DroppedBulkEntry(
                key: String(index),
                localId: id,
                payloadJson: "{}",
                error: MarfaError(code: "invalid_type", message: "refused", status: 0)
            )
        }

        // The dead-letter rows and the removal of the live record are separate
        // saves. A crash between them leaves the record queued with its rows
        // already written, and the replay that follows is the same record,
        // refused the same way, arriving here under the same ids.
        try await queue.recordDroppedBulkEntries(
            record: record, entries: refused, droppedAt: Date()
        )
        try await queue.recordDroppedBulkEntries(
            record: record, entries: refused, droppedAt: Date()
        )

        // One row per refused entry, not two. An app counting what it has
        // lost would otherwise count each entry twice.
        let dropped = try await queue.fetchDropped()
        #expect(dropped.count == 2)
        #expect(Set(dropped.map(\.id)).count == 2)
        #expect(Set(dropped.map(\.localId)) == Set(ids.map { Optional($0) }))
    }
}
