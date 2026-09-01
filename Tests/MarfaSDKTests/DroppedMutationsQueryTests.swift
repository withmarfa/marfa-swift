import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport
import SwiftData

/// Tests for ``DroppedMutationsQuery`` — the reactive surface over the
/// persisted dropped-mutation log.
@Suite("DroppedMutationsQuery")
@MainActor
struct DroppedMutationsQueryTests {

    /// Builds a synced-mode store (with sync engine + mutation queue
    /// attached) so `queryDroppedMutations()` returns non-nil.
    private func makeSyncedFixture() async throws -> (
        store: MarfaStore,
        queue: MutationQueue,
        container: ModelContainer
    ) {
        let (localStore, queue, container) = try await MarfaSDKTest.makeInMemoryStorePair()
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: localStore,
            mutationQueue: queue,
            connectionManager: connManager
        )
        let store = MarfaStore(
            container: container,
            localStore: localStore,
            syncEngine: engine,
            mutationQueue: queue
        )
        return (store, queue, container)
    }

    @Test("initial state is empty")
    func initialStateIsEmpty() async throws {
        let (store, _, _) = try await makeSyncedFixture()
        let query = try #require(store.queryDroppedMutations())
        try await waitUntil(description: "!query.isLoading") { !query.isLoading }
        #expect(query.dropped.isEmpty)
        #expect(query.isEmpty)
        query.stop()
    }

    @Test("recordDropped triggers a refresh and surfaces the row")
    func recordDroppedTriggersRefresh() async throws {
        let (store, queue, _) = try await makeSyncedFixture()
        let query = try #require(store.queryDroppedMutations())
        try await waitUntil(description: "!query.isLoading") { !query.isLoading }

        try await queue.enqueueDeleteItem(id: "server-D")
        let live = try await queue.fetchAll()
        try await queue.recordDropped(
            record: live[0], droppedAt: Date(),
            error: ValidationError(message: "bad delete")
        )

        try await waitUntil(description: "query.dropped.count == 1") { query.dropped.count == 1 }
        let row = try #require(query.dropped.first)
        #expect(row.kind == .deleteItem)
        #expect(row.localId == "server-D")
        #expect(row.errorCode == "validation_error")
        query.stop()
    }

    @Test("dismissAllDropped via store clears the query")
    func dismissAllViaStoreClears() async throws {
        let (store, queue, _) = try await makeSyncedFixture()
        let query = try #require(store.queryDroppedMutations())
        try await waitUntil(description: "!query.isLoading") { !query.isLoading }

        try await queue.enqueueDeleteItem(id: "server-A")
        try await queue.enqueueDeleteItem(id: "server-B")
        let live = try await queue.fetchAll()
        for record in live {
            try await queue.recordDropped(
                record: record, droppedAt: Date(),
                error: ValidationError(message: "x")
            )
        }
        try await waitUntil(description: "query.dropped.count == 2") { query.dropped.count == 2 }

        try await store.dismissAllDropped()

        try await waitUntil(description: "query.dropped.isEmpty") { query.dropped.isEmpty }
        query.stop()
    }

    @Test("queryDroppedMutations returns nil for stores without a sync engine")
    func nilForStoresWithoutEngine() async throws {
        let (localStore, _, container) = try await MarfaSDKTest.makeInMemoryStorePair()
        // No syncEngine, no queue.
        let store = MarfaStore(container: container, localStore: localStore)
        #expect(store.queryDroppedMutations() == nil)
    }
}
