import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport
import SwiftData

/// Tests for ``FullSyncStateQuery`` — the reactive surface over the
/// engine's ``FullSyncState``.
@Suite("FullSyncStateQuery", .timeLimit(.minutes(1)))
@MainActor
struct FullSyncStateQueryTests {

    /// Builds a synced-mode fixture: shared `ModelContainer`, a
    /// `MockTransport`, a real `SyncEngine`, and a `MarfaStore` ready to
    /// vend `FullSyncStateQuery`.
    private func makeFixture() async throws -> (
        store: MarfaStore,
        queue: MutationQueue,
        transport: MockTransport,
        connManager: ConnectionStateManager,
        engine: SyncEngine
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
        let store = MarfaStore(container: container, localStore: localStore, syncEngine: engine)
        return (store, queue, transport, connManager, engine)
    }

    @Test("initial state is .notYetSynced when no timestamp persisted")
    func initialStateIsNotYetSynced() async throws {
        let (store, _, _, _, _) = try await makeFixture()
        let query = try #require(store.queryFullSyncState())

        // Initial state is the static enum default. The init Task
        // for the persisted-timestamp seed runs, sees nothing, and
        // leaves the state as-is.
        if case .notYetSynced = query.state { } else {
            Issue.record("expected .notYetSynced; got \(query.state)")
        }
        query.stop()
    }

    @Test("initial state seeds to .synced(at:) from persisted timestamp")
    func initialStateSeedsFromPersistedTimestamp() async throws {
        let (store, queue, _, _, _) = try await makeFixture()
        let stamp = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        try await queue.saveSyncState(key: "last_clean_drain_at", value: stamp)

        let query = try #require(store.queryFullSyncState())

        try await waitUntil(

            description: "query.state becomes .synced"

        ) {

            if case .synced = query.state { return true }

            return false

        }
        query.stop()
    }

    @Test("`.syncing` event from engine flips state to .syncing")
    func syncingEventFlipsState() async throws {
        let (store, queue, transport, connManager, engine) = try await makeFixture()
        let query = try #require(store.queryFullSyncState())

        // Enqueue work and stage a transient failure so the drain
        // hangs on the .syncing state long enough to observe.
        // Without a queued mutation, replayMutations would short-
        // circuit through the empty-queue clean-drain path and
        // never emit `.syncing`.
        try await queue.enqueueDeleteItem(id: "syncing-probe")
        let netError = NetworkError(
            NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "offline"])
        )
        transport.enqueueError(netError)

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // The cycle emits `.syncing` and then `.failed`. We assert
        // both arrive in order — the query should land on `.failed`
        // having passed through `.syncing`.
        try await waitUntil(
            description: "query.state becomes .failed"
        ) {
            if case .failed = query.state { return true }
            return false
        }
        query.stop()
    }

    @Test("clean drain emits .synced(at:) and the query reflects it")
    func cleanDrainLandsAsSynced() async throws {
        let (store, _, _, connManager, engine) = try await makeFixture()
        let query = try #require(store.queryFullSyncState())

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        try await waitUntil(

            description: "query.state becomes .synced"

        ) {

            if case .synced = query.state { return true }

            return false

        }
        query.stop()
    }

    @Test("transient failure lands as .failed and clears on next clean drain")
    func transientFailureRecoveryCycle() async throws {
        let (store, queue, transport, connManager, engine) = try await makeFixture()
        let query = try #require(store.queryFullSyncState())

        // Cycle 1 — transient failure.
        try await queue.enqueueDeleteItem(id: "server-z")
        let netError = NetworkError(
            NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "offline"])
        )
        transport.enqueueError(netError)
        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        try await waitUntil(

            description: "query.state becomes .failed"

        ) {

            if case .failed = query.state { return true }

            return false

        }

        // Cycle 2 — same row replays cleanly.
        await connManager.applyStateForTesting(.online)
        transport.enqueue(EmptyResponse())
        await engine.triggerProactiveDrainForTesting()

        try await waitUntil(

            description: "query.state becomes .synced"

        ) {

            if case .synced = query.state { return true }

            return false

        }
        query.stop()
    }

    @Test("connection-manager state changes do not perturb query state")
    func connectionStateChangesDoNotPerturbQuery() async throws {
        // Regression guard for the original two-stream design that
        // raced `markSyncing` against `recordCleanDrain` — the
        // connection-manager `.syncing` could overwrite a freshly
        // applied `.synced` at the @MainActor consumer. The current
        // single-stream design subscribes only to engine events,
        // so connection-manager flaps are inert.
        let (store, _, _, connManager, engine) = try await makeFixture()
        let query = try #require(store.queryFullSyncState())

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()
        try await waitUntil(
            description: "query.state becomes .synced"
        ) {
            if case .synced = query.state { return true }
            return false
        }

        // Flap the connection state through every transition — none
        // should reach the query, because only engine events do.
        await connManager.applyStateForTesting(.connecting)
        await connManager.applyStateForTesting(.online)
        await connManager.applyStateForTesting(.syncing)
        await connManager.applyStateForTesting(.online)

        // Settle window — give the (no-op) listener a chance to mis-
        // handle if it ever drifts back to subscribing.
        try await Task.sleep(for: .milliseconds(50))
        if case .synced = query.state { } else {
            Issue.record("expected .synced to be preserved; got \(query.state)")
        }
        query.stop()
    }

    @Test("queryFullSyncState returns nil for stores without a sync engine")
    func nilForStoresWithoutEngine() async throws {
        let (localStore, _, container) = try await MarfaSDKTest.makeInMemoryStorePair()
        // No syncEngine.
        let store = MarfaStore(container: container, localStore: localStore)
        #expect(store.queryFullSyncState() == nil)
    }
}
