import Testing
import Foundation
@testable import MymeSDK
@testable import MymeSDKTestSupport
import SwiftData

/// Tests for ``DroppedMutationsQuery`` — the reactive surface over the
/// persisted dropped-mutation log.
@Suite("DroppedMutationsQuery")
@MainActor
struct DroppedMutationsQueryTests {

    /// Builds a synced-mode store (with sync engine + mutation queue
    /// attached) so `queryDroppedMutations()` returns non-nil.
    private func makeSyncedFixture() async throws -> (
        store: MymeStore,
        queue: MutationQueue,
        container: ModelContainer
    ) {
        let (localStore, queue, container) = try await MymeSDKTest.makeInMemoryStorePair()
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: localStore,
            mutationQueue: queue,
            connectionManager: connManager
        )
        let store = MymeStore(
            container: container,
            syncEngine: engine,
            mutationQueue: queue
        )
        return (store, queue, container)
    }

    /// Reactive queries refresh via `ModelContext.didSave` + a 50 ms
    /// debounce. Default timeout matches the rest of the reactive
    /// suite — generous to absorb CI variance.
    private func waitUntil(
        timeout: Duration = .seconds(5),
        every: Duration = .milliseconds(10),
        _ condition: @MainActor () async throws -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if try await condition() { return }
            try await Task.sleep(for: every)
        }
        if try await condition() { return }
        Issue.record("waitUntil: condition never satisfied within \(timeout)")
    }

    @Test("initial state is empty")
    func initialStateIsEmpty() async throws {
        let (store, _, _) = try await makeSyncedFixture()
        let query = try #require(store.queryDroppedMutations())
        try await waitUntil { !query.isLoading }
        #expect(query.dropped.isEmpty)
        #expect(query.isEmpty)
        query.stop()
    }

    @Test("recordDropped triggers a refresh and surfaces the row")
    func recordDroppedTriggersRefresh() async throws {
        let (store, queue, _) = try await makeSyncedFixture()
        let query = try #require(store.queryDroppedMutations())
        try await waitUntil { !query.isLoading }

        try await queue.enqueueDeleteItem(id: "server-D")
        let live = try await queue.fetchAll()
        try await queue.recordDropped(
            record: live[0], droppedAt: Date(),
            error: ValidationError(message: "bad delete")
        )

        try await waitUntil { query.dropped.count == 1 }
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
        try await waitUntil { !query.isLoading }

        try await queue.enqueueDeleteItem(id: "server-A")
        try await queue.enqueueDeleteItem(id: "server-B")
        let live = try await queue.fetchAll()
        for record in live {
            try await queue.recordDropped(
                record: record, droppedAt: Date(),
                error: ValidationError(message: "x")
            )
        }
        try await waitUntil { query.dropped.count == 2 }

        try await store.dismissAllDropped()

        try await waitUntil { query.dropped.isEmpty }
        query.stop()
    }

    @Test("queryDroppedMutations returns nil for stores without a sync engine")
    func nilForStoresWithoutEngine() async throws {
        let (_, _, container) = try await MymeSDKTest.makeInMemoryStorePair()
        let store = MymeStore(container: container) // no syncEngine, no queue
        #expect(store.queryDroppedMutations() == nil)
    }
}
