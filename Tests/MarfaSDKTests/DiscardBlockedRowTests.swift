import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// Discarding a blocked write, and the item it was holding back.
///
/// **A blocked row is not only a write that failed; it is a lock on its item.**
/// `replayableRecords` defers every later write to an item behind that item's
/// earliest blocked row, deliberately — releasing them out of order is how an
/// edit gets lost. Exactly one reason is exempt, `resolverMissing` once a
/// resolver is registered.
///
/// So a row that no remedy can release strands the item as well as itself, and
/// two reasons have no remedy: a spent idempotency key is refused identically
/// however often it is sent, and a conflict the server declined comes back from
/// the server's own idempotency record because the row's key never changes.
/// The second is the ordinary outcome for an `.auto` write.
///
/// Before this door the only exits were `retry(id:)` and `retryAll(reason:)`,
/// both of which release the row into the same refusal. There was no way to
/// stop asking.
@Suite("Discarding a blocked write", .timeLimit(.minutes(1)))
struct DiscardBlockedRowTests {

    /// A queue whose only row is blocked on a spent key, plus a later edit to
    /// the same item sitting behind it.
    private func queueWithABlockedRowAndAnEditBehindIt()
        async throws -> (LocalStore, MutationQueue, blockedId: String, laterId: String)
    {
        // **The pair, not two halves of two pairs.** `makeInMemoryStorePair`
        // returns a store and a queue sharing one container, which is the shape
        // `MarfaClient.synced` produces. Calling it twice and keeping one half
        // of each gave an engine whose store and queue were unrelated
        // databases — a configuration production cannot make, and the reason
        // nothing here could assert on the store side of a discard.
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)

        try await queue.enqueueUpdateItem(
            id: "server-1", properties: ["body": .string("first edit")],
            version: 1, conflict: .auto, tier: nil, sourceId: nil
        )
        let first = try #require(try await queue.fetchAll().first)
        try await queue.recordBlocked(
            id: first.id,
            reason: .idempotencyKeyReused,
            error: "code=idempotency_key_reused status=422 message=key already answered a different body"
        )

        // **Separated deliberately.** `createdAt` is millisecond-resolution
        // ISO, and the deferral compares `>=` — so two enqueues in the same
        // millisecond tie, and a tie waits. The test would still pass, but
        // through the liveness branch rather than the ordering property it
        // claims to set up, and a future `>` would make it flake rather than
        // fail. `SyncEngineBlockedMutationTests` separates for the same reason.
        try await Task.sleep(for: .milliseconds(5))

        // Queued after the block, against the same item. This is the write the
        // deferral holds, and the one a person makes when they try again.
        try await queue.enqueueUpdateItem(
            id: "server-1", properties: ["body": .string("second edit")],
            version: 1, conflict: .auto, tier: nil, sourceId: nil
        )
        let later = try #require(
            try await queue.fetchAll().first { $0.id != first.id }
        )
        // The ordering the deferral turns on, asserted rather than assumed.
        #expect(later.createdAt > first.createdAt)
        return (store, queue, blockedId: first.id, laterId: later.id)
    }

    /// An engine over that queue, plus the transport it talks to.
    private func engine(over store: LocalStore, _ queue: MutationQueue) async throws
        -> (SyncEngine, MockTransport, ConnectionStateManager)
    {
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport, localStore: store, mutationQueue: queue,
            connectionManager: connManager
        )
        return (engine, transport, connManager)
    }

    /// The item ids of every write the drain actually sent.
    private func sentItemIds(_ transport: MockTransport) async -> [String] {
        await transport.calls
            .filter { $0.method == .patch && $0.path.hasPrefix("/items/") }
            .map { String($0.path.dropFirst("/items/".count)) }
    }

    @Test("a blocked row holds back a later write to the same item")
    func aBlockedRowHoldsBackALaterWrite() async throws {
        let (store, queue, _, _) = try await queueWithABlockedRowAndAnEditBehindIt()
        let (engine, transport, connManager) = try await engine(over: store, queue)

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // **The premise the door exists for**, asserted on the wire rather than
        // on the engine's internal decision: the second edit is never sent, and
        // it is not blocked itself — it is waiting behind a row that will never
        // move. Without this the rest of the suite would be about a problem
        // that does not exist.
        #expect(await sentItemIds(transport).isEmpty, "the deferred edit reached the server")
        let waiting = try await queue.fetchAll()
        #expect(waiting.count == 2, "both rows are still queued")
    }

    @Test("discarding releases the item, and keeps what was discarded")
    func discardingReleasesTheItem() async throws {
        let (store, queue, blockedId, laterId) = try await queueWithABlockedRowAndAnEditBehindIt()
        let (engine, transport, connManager) = try await engine(over: store, queue)
        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()
        #expect(await sentItemIds(transport).isEmpty)

        try await engine.discard(id: blockedId)
        await engine.triggerProactiveDrainForTesting()

        // The item takes writes again, which is the whole point: discarding is
        // about the item as much as about the row.
        #expect(
            await sentItemIds(transport) == ["server-1"],
            "the edit that was waiting behind the blocked row still has not been sent"
        )
        let remaining = try await queue.fetchAll()
        #expect(!remaining.contains { $0.id == blockedId })
        // Deliberately not asserting the released row has left the queue.
        // Whether it *lands* depends on the server's answer, which this
        // fixture does not stage — and the door's promise is that the write is
        // attempted again, not that it succeeds. Asserting delivery here would
        // be asserting about MockTransport.
        #expect(remaining.contains { $0.id == laterId })

        // **Nothing vanishes unrecorded.** A discarded write is still a write
        // somebody made, and the dead-letter log is where an app finds it.
        let dropped = try await queue.fetchDropped()
        let record = try #require(dropped.first { $0.id == blockedId })
        #expect(record.kind == .updateItem)
        // `localId` ties the dead letter back to the item, and it is the same
        // key the deferral was built on — so a reader can see which item was
        // released as well as which write was dropped.
        #expect(record.localId == "server-1")
        #expect(record.errorCode == MarfaError.discardedByAppCode)
        #expect(record.errorStatus == 0, "nobody refused this write")
    }

    @Test("discarding a blocked create takes the ghost item and its orphans with it")
    func discardingACreateCascades() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let (engine, transport, connManager) = try await engine(over: store, queue)

        // A create and an edit of the thing it creates, which is the ordinary
        // offline shape: make a note, type into it.
        let created = try await store.createItem(
            CreateItemInput(type: "core.note", properties: ["body": .string("new")])
        )
        try await queue.enqueueCreateItem(
            CreateItemInput(
                type: "core.note",
                properties: ["body": .string("new")],
                id: created.id
            ),
            localId: created.id
        )
        try await Task.sleep(for: .milliseconds(5))
        try await queue.enqueueUpdateItem(
            id: created.id, properties: ["body": .string("edited")],
            version: 1, conflict: .auto, tier: nil, sourceId: nil
        )
        let createRow = try #require(
            try await queue.fetchAll().first { $0.kind == .createItem }
        )
        // **One refused credential parks every live row**, creates included —
        // `parkAllLive` filters on state and not on kind. So this is not an
        // exotic way to get a blocked create in front of the door; it is the
        // ordinary one.
        _ = try await queue.parkAllLive(
            reason: .credentialRefused, error: "code=unauthorized status=401 message=key revoked"
        )

        try await engine.discard(id: createRow.id)

        // **The edit must not be released.** Freed, it would go to a server
        // that has never heard of this item, 404, and be dead-lettered on its
        // own — so "releases the item it was holding back" would be exactly
        // inverted for a create.
        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()
        #expect(await sentItemIds(transport).isEmpty, "an orphaned edit reached the server")
        #expect(try await queue.fetchAll().isEmpty, "the orphaned edit is still queued")

        // Both rows are in the dead-letter log, and the ghost item is gone from
        // the store rather than sitting there unsyncable forever.
        let dropped = try await queue.fetchDropped()
        #expect(dropped.count == 2)
        // `fetchItem` throws for a row that is not there, which is the
        // assertion: the ghost is gone rather than merely hidden.
        await #expect(throws: (any Error).self, "a ghost item survived the discard") {
            _ = try await store.fetchItem(id: created.id)
        }
    }

    @Test("discarding a blocked upload does not strand its bytes")
    func discardingAnUploadReleasesItsBytes() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let (engine, _, _) = try await engine(over: store, queue)

        let bytes = Data("some image bytes".utf8)
        let hash = "sha256:" + String(repeating: "b", count: 64)
        try await queue.enqueueBlobUpload(hash: hash, data: bytes, mimeType: "image/jpeg")
        let row = try #require(try await queue.fetchAll().first { $0.kind == .uploadBlob })
        _ = try await queue.parkAllLive(
            reason: .credentialRefused, error: "code=unauthorized status=401 message=key revoked"
        )
        #expect(try await queue.fetchPendingBlob(hash: hash) != nil, "the fixture staged no bytes")

        try await engine.discard(id: row.id)

        // **Staged bytes sit outside the eviction walk on purpose** — they are
        // owed to a server. Nothing is owed once the row is discarded, and the
        // only other deleter is the successful-upload path, so without this
        // they are unreachable by every query and never freed.
        #expect(
            try await queue.fetchPendingBlob(hash: hash) == nil,
            "the staged bytes outlived the write that owned them"
        )
    }

    @Test("discarding one upload does not take a sibling's bytes")
    func discardingOneUploadKeepsASiblingsBytes() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let (engine, _, _) = try await engine(over: store, queue)

        // **One `PendingBlobModel`, two mutation rows.** Enqueuing the same
        // content twice while offline is a shape the queue documents as
        // supported: the bytes are stored once and each write gets its own row.
        let bytes = Data("shared image bytes".utf8)
        let hash = "sha256:" + String(repeating: "c", count: 64)
        try await queue.enqueueBlobUpload(hash: hash, data: bytes, mimeType: "image/jpeg")
        try await Task.sleep(for: .milliseconds(5))
        try await queue.enqueueBlobUpload(hash: hash, data: bytes, mimeType: "image/jpeg")
        let rows = try await queue.fetchAll().filter { $0.kind == .uploadBlob }
        #expect(rows.count == 2, "the fixture did not produce two rows for one blob")
        _ = try await queue.parkAllLive(
            reason: .credentialRefused, error: "code=unauthorized status=401 message=key revoked"
        )

        try await engine.discard(id: rows[0].id)

        // Deleting on hash alone would take these with it, and the surviving
        // row would then replay, find nothing, and be dead-lettered on a
        // permanent 400 — the bytes gone from the device with nothing said.
        #expect(
            try await queue.fetchPendingBlob(hash: hash) != nil,
            "discarding one upload destroyed the bytes another queued write still owes"
        )
        #expect(try await queue.fetchAll().contains { $0.id == rows[1].id })

        // And once the last owner goes, they are freed.
        try await engine.discard(id: rows[1].id)
        #expect(try await queue.fetchPendingBlob(hash: hash) == nil)
    }

    @Test("only a blocked row can be discarded")
    func onlyABlockedRowCanBeDiscarded() async throws {
        let (store, queue, _, laterId) = try await queueWithABlockedRowAndAnEditBehindIt()
        let (engine, _, _) = try await engine(over: store, queue)

        // **A pending row is the drain's to own.** Discarding one races the
        // cycle that may already be sending it, and "I gave up on that" is not
        // a thing anyone can mean about a write still being attempted.
        await #expect(throws: DiscardNotBlockedError.self) {
            try await engine.discard(id: laterId)
        }
        #expect(try await queue.fetchAll().contains { $0.id == laterId })
    }

    @Test("discarding a row that is not there is not an error")
    func discardingAnAbsentRowIsQuiet() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        let (engine, _, _) = try await engine(over: store, queue)

        // Two taps on the same row, or a discard racing a drain that dropped
        // it. The caller's intent is already satisfied, so this is not news.
        try await engine.discard(id: "no-such-row")
    }
}
