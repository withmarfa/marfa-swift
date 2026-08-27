import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// Externally-observable sync state on the engine:
/// - `hasPendingMutations` — accessor over the queue.
/// - `lastFullSyncAt` — timestamp of the most recent `performInitialSync`.
/// - `lastCleanDrainAt` / `fullSyncState` — checkpoint introduced in 5.1.0,
///   reporting whether the queue has been drained cleanly since the last
///   transient failure. Both accessors persist across `SyncEngine`
///   instances on the same store and seed `fullSyncState` from disk on
///   first access.
///
/// Shared helpers live in ``SyncEngineTestKit`` (see SyncEngineTestSupport.swift).
@Suite("SyncEngine state tracking", .timeLimit(.minutes(1)))
struct SyncEngineStateTrackingTests {

    // MARK: - hasPendingMutations

    @Test("hasPendingMutations is false on a fresh engine")
    func hasPendingMutationsFalseWhenEmpty() async throws {
        let (_, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        #expect(try await engine.hasPendingMutations == false)
    }

    @Test("hasPendingMutations tracks enqueue and remove")
    func hasPendingMutationsTracksQueue() async throws {
        let (_, queue, _, _, engine) = try await SyncEngineTestKit.makeFixture()

        try await queue.enqueueDeleteItem(id: "server-1")
        #expect(try await engine.hasPendingMutations == true)

        let records = try await queue.fetchAll()
        try await queue.remove(id: records[0].id)
        #expect(try await engine.hasPendingMutations == false)
    }

    // MARK: - lastFullSyncAt

    @Test("lastFullSyncAt is nil on a fresh store")
    func lastFullSyncAtNilOnFreshStore() async throws {
        let (_, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        let stamped = await engine.lastFullSyncAt
        #expect(stamped == nil)
    }

    @Test("performInitialSync stamps lastFullSyncAt")
    func performInitialSyncStampsLastFullSyncAt() async throws {
        let (_, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueue(
            PaginatedResult<ItemWithMetadata>(data: [], cursor: nil, hasMore: false)
        )
        transport.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))

        let before = Date()
        _ = try await engine.performInitialSync()
        let after = Date()

        let stamped = await engine.lastFullSyncAt
        #expect(stamped != nil)
        if let s = stamped {
            #expect(s >= before.addingTimeInterval(-1))
            #expect(s <= after.addingTimeInterval(1))
        }
    }

    @Test("lastFullSyncAt persists across SyncEngine instances on the same store")
    func lastFullSyncAtPersistsAcrossEngines() async throws {
        let (store, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueue(
            PaginatedResult<ItemWithMetadata>(data: [], cursor: nil, hasMore: false)
        )
        transport.enqueue(PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false))
        _ = try await engine.performInitialSync()
        let first = await engine.lastFullSyncAt
        #expect(first != nil)

        // Fresh engine sharing the same local store + queue reads the
        // same `sync_state` rows.
        let engine2 = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        let second = await engine2.lastFullSyncAt
        #expect(second == first)
    }

    // MARK: - lastCleanDrainAt + fullSyncState

    @Test("lastCleanDrainAt is nil on a fresh store")
    func lastCleanDrainAtNilOnFreshStore() async throws {
        let (_, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        let stamped = await engine.lastCleanDrainAt
        #expect(stamped == nil)
    }

    @Test("fullSyncState is .notYetSynced on a fresh store")
    func fullSyncStateNotYetSyncedOnFreshStore() async throws {
        let (_, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        let state = await engine.fullSyncState
        if case .notYetSynced = state { } else {
            Issue.record("expected .notYetSynced; got \(state)")
        }
    }

    @Test("clean drain against an empty queue stamps lastCleanDrainAt")
    func cleanDrainAgainstEmptyQueueStampsLastCleanDrainAt() async throws {
        let (_, _, _, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        await connManager.applyStateForTesting(.online)

        let before = Date()
        await engine.triggerProactiveDrainForTesting()
        let after = Date()

        let stamped = await engine.lastCleanDrainAt
        #expect(stamped != nil)
        if let s = stamped {
            #expect(s >= before.addingTimeInterval(-1))
            #expect(s <= after.addingTimeInterval(1))
        }
    }

    @Test("fullSyncState reports .synced after a clean drain")
    func fullSyncStateSyncedAfterCleanDrain() async throws {
        let (_, _, _, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        let state = await engine.fullSyncState
        if case .synced = state { } else {
            Issue.record("expected .synced(at:); got \(state)")
        }
    }

    @Test("clean drain after queued mutation stamps lastCleanDrainAt")
    func cleanDrainAfterQueuedMutationStampsTimestamp() async throws {
        let (_, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        await connManager.applyStateForTesting(.online)

        // One queued mutation that the transport will accept cleanly.
        try await queue.enqueueDeleteItem(id: "server-x")
        transport.enqueue(EmptyResponse())

        await engine.triggerProactiveDrainForTesting()

        let stamped = await engine.lastCleanDrainAt
        #expect(stamped != nil)
        #expect(try await queue.isEmpty)
    }

    @Test("transient failure does not stamp lastCleanDrainAt and reports .failed")
    func transientFailureSkipsTimestampAndReportsFailed() async throws {
        let (_, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        await connManager.applyStateForTesting(.online)

        try await queue.enqueueDeleteItem(id: "server-x")
        let netError = NetworkError(
            NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "offline"])
        )
        transport.enqueueError(netError)

        await engine.triggerProactiveDrainForTesting()

        let stamped = await engine.lastCleanDrainAt
        #expect(stamped == nil)

        let state = await engine.fullSyncState
        if case .failed = state { } else {
            Issue.record("expected .failed; got \(state)")
        }
        // Transient failure leaves the row in the queue for retry.
        #expect(try await queue.isEmpty == false)
    }

    @Test("fullSyncState clears .failed back to .synced on next clean drain")
    func fullSyncStateClearsFailedAfterNextCleanDrain() async throws {
        let (_, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        await connManager.applyStateForTesting(.online)

        // Cycle 1 — transient failure.
        try await queue.enqueueDeleteItem(id: "server-y")
        let netError = NetworkError(
            NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "offline"])
        )
        transport.enqueueError(netError)
        await engine.triggerProactiveDrainForTesting()

        if case .failed = await engine.fullSyncState { } else {
            Issue.record("expected .failed after first cycle")
        }

        // Cycle 2 — same row replays cleanly. Reset state to .online
        // because the previous fireProactiveDrain ended with markOnline,
        // but the actor-state assertion is worth being explicit about.
        await connManager.applyStateForTesting(.online)
        transport.enqueue(EmptyResponse())
        await engine.triggerProactiveDrainForTesting()

        #expect(try await queue.isEmpty)
        if case .synced = await engine.fullSyncState { } else {
            Issue.record("expected .synced after recovery cycle")
        }
    }

    @Test("lastCleanDrainAt persists across SyncEngine instances on the same store")
    func lastCleanDrainAtPersistsAcrossEngines() async throws {
        let (store, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        let first = await engine.lastCleanDrainAt
        #expect(first != nil)

        // Fresh engine sharing the same local store + queue reads the
        // same `sync_state` row.
        let engine2 = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        let second = await engine2.lastCleanDrainAt
        #expect(second == first)
    }

    @Test("FullSyncState seeds from persisted lastCleanDrainAt on a new engine")
    func fullSyncStateSeedsFromPersistedTimestamp() async throws {
        let (store, queue, transport, connManager, _) = try await SyncEngineTestKit.makeFixture()

        // Seed the persisted timestamp directly — simulating a prior
        // session that completed a clean drain.
        let stamp = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        try await queue.saveSyncState(key: "last_clean_drain_at", value: stamp)

        // Fresh engine reads the persisted state on first access.
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        if case .synced = await engine.fullSyncState { } else {
            Issue.record("expected .synced from persisted timestamp")
        }
    }
}
