import Foundation
import Testing
@testable import MarfaSDK
import MarfaSDKTestSupport

/// The initial sync's refusal to import over work that has not replayed.
///
/// `upsertItem` replaces every column with no version check and
/// `upsertMetadata` replaces the whole metadata row, and the conflict
/// machinery is unreachable from
/// the import — it only runs on an outbound update meeting a 409. So before
/// this the import silently preferred the server's older body to a local edit
/// that had not left the device.
@Suite("The initial sync refuses to clobber a queued edit", .timeLimit(.minutes(1)))
struct SyncEngineInitialSyncRefusalTests {

    private func pair(_ id: String) -> ItemWithMetadata {
        ItemWithMetadata(
            item: Item(
                createdAt: "2026-08-26T09:00:00Z",
                id: id,
                properties: ["body": .string("from the server")],
                schemaVersion: 1,
                source: "test",
                state: .active,
                tier: .feed,
                timestamp: "2026-08-26T09:00:00Z",
                type: "core.note",
                updatedAt: "2026-08-26T09:00:00Z",
                version: 1
            ),
            metadata: Metadata(extensions: [:], itemId: id, tags: [])
        )
    }

    @Test("a queued write stops the import")
    func refusesWhileAWriteIsQueued() async throws {
        let (_, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await queue.enqueueDeleteItem(id: "server-1")
        transport.enqueue(
            PaginatedResult<ItemWithMetadata>(data: [pair("i1")], cursor: nil, hasMore: false)
        )

        await #expect(throws: InitialSyncError.self) {
            _ = try await engine.performInitialSync()
        }
    }

    @Test("the refusal says how many writes are outstanding")
    func refusalCarriesTheCount() async throws {
        let (_, queue, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await queue.enqueueDeleteItem(id: "server-1")
        try await queue.enqueueDeleteItem(id: "server-2")
        try await queue.enqueueDeleteItem(id: "server-3")

        do {
            _ = try await engine.performInitialSync()
            Issue.record("Expected the import to refuse")
        } catch let error as InitialSyncError {
            // A count that does not fall across retries is a stuck queue rather
            // than a busy one, which is the distinction a bare "try later"
            // cannot carry.
            guard case .pendingMutations(let count) = error else {
                Issue.record("Expected .pendingMutations, got \(error)")
                return
            }
            #expect(count == 3)
        }
    }

    @Test("it refuses before asking the server for anything")
    func refusesBeforeTouchingTheNetwork() async throws {
        let (_, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await queue.enqueueDeleteItem(id: "server-1")

        _ = try? await engine.performInitialSync()

        // Not merely a matter of taste: a page fetched and then discarded is a
        // page the server paid for, and on a large library it is many.
        let calls = await transport.calls
        #expect(calls.isEmpty)
    }

    @Test("nothing reaches the store when it refuses")
    func storeIsUntouchedOnRefusal() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await queue.enqueueDeleteItem(id: "server-1")
        transport.enqueue(
            PaginatedResult<ItemWithMetadata>(data: [pair("i1")], cursor: nil, hasMore: false)
        )

        _ = try? await engine.performInitialSync()

        let stored = try await store.fetchItems(filters: nil)
        #expect(stored.data.isEmpty)
    }

    @Test("it imports once the queue has drained")
    func importsAfterTheQueueDrains() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await queue.enqueueDeleteItem(id: "server-1")

        // Refused while queued.
        await #expect(throws: InitialSyncError.self) {
            _ = try await engine.performInitialSync()
        }

        let records = try await queue.fetchAll()
        try await queue.remove(id: records[0].id)

        transport.enqueue(
            PaginatedResult<ItemWithMetadata>(data: [pair("i1")], cursor: nil, hasMore: false)
        )
        transport.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))

        let imported = try await engine.performInitialSync()
        #expect(imported == 1)
        let stored = try await store.fetchItems(filters: nil)
        #expect(stored.data.map(\.id) == ["i1"])
    }

    @Test("catchup_too_old drains the queue before it asks for a full import")
    func catchupDrainsBeforeImporting() async throws {
        let (_, queue, transport, connManager, engine) =
            try await SyncEngineTestKit.makeFixture()

        // A write that has not replayed, and a cursor as if the device had been
        // running for a while.
        try await queue.enqueueDeleteItem(id: "server-1")
        try await queue.saveSyncState(key: "last_event_id", value: "evt-stale")

        let catchup = SSEEvent(
            id: nil,
            event: "catchup_too_old",
            data: #"{"type":"catchup_too_old","min_retained_id":100,"requested":50}"#
        )
        transport.enqueueEvents([catchup])
        transport.enqueue(EmptyResponse())   // the queued delete replaying
        transport.enqueue(PaginatedResult<ItemWithMetadata>(data: [], cursor: nil, hasMore: false))
        transport.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))
        transport.enqueueEvents([])

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        // The point of the drain. Without it the import refuses, and this is
        // the one branch that can do anything about it: the cursor has already
        // been cleared, a reconnect resumes from nothing, and nothing else ever
        // asks for a full import — so a refusal here is a gap with no route
        // back rather than a retry.
        try await SyncEngineTestKit.awaitCondition(description: "transport.calls.contains an /items GET") {
            await transport.calls.contains { $0.path == "/items" && $0.method == .get }
        }

        let deleteReplayed = await transport.calls.contains {
            $0.path == "/items/server-1" && $0.method == .delete
        }
        #expect(deleteReplayed, "the queued write should have replayed first")
        #expect(try await engine.hasPendingMutations == false)

        await engine.stop()
    }

    @Test("the refusal describes itself rather than reporting a case index")
    func refusalIsReadable() async throws {
        // The lesson `OAuthDiscoveryError` cost an afternoon for: a SwiftUI
        // error row shows `localizedDescription`, and without `LocalizedError`
        // that renders the case index instead of the sentence.
        let one = InitialSyncError.pendingMutations(count: 1)
        let many = InitialSyncError.pendingMutations(count: 4)

        #expect(one.localizedDescription.contains("1 local write"))
        #expect(many.localizedDescription.contains("4 local writes"))
        #expect(many.localizedDescription.contains("overwrite"))
        #expect(!many.localizedDescription.contains("couldn't be completed"))
    }
}
