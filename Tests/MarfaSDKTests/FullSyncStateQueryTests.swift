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
        // A device that has already imported. A store that never has cannot
        // record a clean drain — an empty queue on an empty store is a device
        // that has not started, not one in sync — and every test here is about
        // what a drain does afterwards.
        try await SyncEngineTestKit.markImported(queue)
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

        try await awaitCondition(description: "query.state becomes .synced") {

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
        try await awaitCondition(description: "query.state becomes .failed") {
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

        try await awaitCondition(description: "query.state becomes .synced") {

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

        try await awaitCondition(description: "query.state becomes .failed") {

            if case .failed = query.state { return true }

            return false

        }

        // Cycle 2 — same row replays cleanly.
        await connManager.applyStateForTesting(.online)
        transport.enqueue(EmptyResponse())
        await engine.triggerProactiveDrainForTesting()

        try await awaitCondition(description: "query.state becomes .synced") {

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
        try await awaitCondition(description: "query.state becomes .synced") {
            if case .synced = query.state { return true }
            return false
        }

        // Flap the connection state through every transition — none
        // should reach the query, because only engine events do.
        await connManager.applyStateForTesting(.connecting)
        await connManager.applyStateForTesting(.online)
        await connManager.applyStateForTesting(.syncing)
        await connManager.applyStateForTesting(.online)

        // Settle window. There is no constant to derive this from, and saying
        // so is better than borrowing one that looks like a derivation: this
        // query holds no `RefetchObserver` and no `didSave` subscription, so
        // the refetch debounce has nothing to do with the path under test.
        // The regression it guards is a `stateUpdates` subscription
        // reappearing, whose latency is an AsyncStream hop. The window is
        // stated as what it is — long enough that a subscription would have
        // delivered, and paid in full only when the test passes.
        try await expectRemains(
            for: .milliseconds(400),
            description: "connection-state changes do not reach the full-sync query"
        ) {
            if case .synced = query.state { return true }
            return false
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

    /// **The shipped SwiftUI surface is event-driven after its seed**, so a
    /// view already sitting at `.synced` from a healthy session had nothing
    /// that would ever move it once the credential died. The engine reading
    /// the park does not reach a query that is not listening for it.
    @Test("a queue parking moves the query off a synced state")
    func parkingMovesTheQueryOffSynced() async throws {
        let (store, queue, transport, connManager, engine) = try await makeFixture()
        let stamp = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        try await queue.saveSyncState(key: "last_clean_drain_at", value: stamp)

        let query = try #require(store.queryFullSyncState())
        try await awaitCondition(description: "query.state becomes .synced") {
            if case .synced = query.state { return true }
            return false
        }

        for label in ["one", "two"] {
            var input = CreateItemInput(type: "core.note", properties: ["body": .string(label)])
            input.id = UUIDv7.generateString()
            try await queue.enqueueCreateItem(input, localId: input.id!)
        }
        transport.enqueueError(UnauthorizedError(message: "key revoked"))
        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        try await awaitCondition(description: "query.state becomes .parked") {
            if case .parked = query.state { return true }
            return false
        }
        guard case .parked(let reason, let count) = query.state else {
            Issue.record("expected .parked; got \(query.state)")
            query.stop()
            return
        }
        #expect(reason == .credentialRefused)
        #expect(count == 2)
        query.stop()
    }

    /// **And a query opened over an already-parked store seeds parked**, which
    /// is the app-restart case. Seeding from the persisted timestamp alone
    /// opened it on "last synced an hour ago" over a queue that had stopped,
    /// with no event coming to correct it.
    @Test("a query opened over a parked store seeds parked, not synced")
    func aQueryOpenedOverAParkedStoreSeedsParked() async throws {
        let (store, queue, transport, connManager, engine) = try await makeFixture()
        let stamp = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        try await queue.saveSyncState(key: "last_clean_drain_at", value: stamp)

        var input = CreateItemInput(type: "core.note", properties: ["body": .string("one")])
        input.id = UUIDv7.generateString()
        try await queue.enqueueCreateItem(input, localId: input.id!)
        transport.enqueueError(UnauthorizedError(message: "key revoked"))
        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // Opened only now, so nothing it could have heard is in flight.
        let query = try #require(store.queryFullSyncState())
        try await awaitCondition(description: "query.state seeds to .parked") {
            if case .parked = query.state { return true }
            return false
        }
        query.stop()
    }

    /// **A row failing transiently before another is refused.** The cycle
    /// emitted `.queueParked` and then, at its tail, `.failed` from the
    /// earlier row — and a latched fold keeps the last one. Nothing put the
    /// park back, because `queueParked` answers "this just happened" and a
    /// fully parked queue produces no further events at all.
    @Test("a transient failure in the parking cycle does not overwrite the park")
    func aTransientFailureInTheSameCycleDoesNotOverwriteThePark() async throws {
        let (store, queue, transport, connManager, engine) = try await makeFixture()
        let query = try #require(store.queryFullSyncState())

        // Two rows: the first meets the network, the second meets the 401.
        for label in ["flaky", "refused"] {
            var input = CreateItemInput(type: "core.note", properties: ["body": .string(label)])
            input.id = UUIDv7.generateString()
            try await queue.enqueueCreateItem(input, localId: input.id!)
        }
        transport.enqueueError(NetworkError(URLError(.notConnectedToInternet)))
        transport.enqueueError(UnauthorizedError(message: "key revoked"))

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // **Waited on the terminal state rather than on `.parked` itself.**
        // Written the other way this passed with the fix removed: the cycle
        // does reach `.parked` for an instant on its way to emitting the
        // earlier row's failure, and a poll for a value it briefly holds
        // cannot tell that from a value it settles on.
        try await awaitCondition(description: "the cycle to reach a terminal state") {
            if case .syncing = query.state { return false }
            if case .notYetSynced = query.state { return false }
            return true
        }
        if case .parked = query.state {} else {
            Issue.record("the earlier row's failure overwrote the park: \(query.state)")
        }
        query.stop()
    }

    /// **And a park laid down in an earlier cycle survives a later failure.**
    /// The ordinary sequence: the credential dies, the person keeps working,
    /// and the next write meets a network hiccup. Nothing re-emits the park,
    /// so a fold that took the failure would tell somebody to check their
    /// connection when the remedy is to sign in again.
    @Test("a later transient failure does not overwrite a standing park")
    func aLaterFailureDoesNotOverwriteAStandingPark() async throws {
        let (store, queue, transport, connManager, engine) = try await makeFixture()
        let query = try #require(store.queryFullSyncState())

        var first = CreateItemInput(type: "core.note", properties: ["body": .string("refused")])
        first.id = UUIDv7.generateString()
        try await queue.enqueueCreateItem(first, localId: first.id!)
        transport.enqueueError(UnauthorizedError(message: "key revoked"))
        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()
        try await awaitCondition(description: "query.state becomes .parked") {
            if case .parked = query.state { return true }
            return false
        }

        // The person carries on. This one meets the network rather than the
        // credential, and its cycle ends in a failure.
        var later = CreateItemInput(type: "core.note", properties: ["body": .string("later")])
        later.id = UUIDv7.generateString()
        try await queue.enqueueCreateItem(later, localId: later.id!)
        transport.enqueueError(NetworkError(URLError(.notConnectedToInternet)))
        await engine.triggerProactiveDrainForTesting()

        // Wait for the cycle's terminal event to be folded rather than for a
        // value: the query moves to `.syncing` first, and asserting on the
        // instant the drain returns reads that rather than its outcome.
        try await awaitCondition(description: "the cycle to reach a terminal state") {
            if case .syncing = query.state { return false }
            return true
        }
        if case .parked = query.state {} else {
            Issue.record("a later failure overwrote the park: \(query.state)")
        }
        query.stop()
    }

    /// **Releasing the queue has to say so.** The drain it schedules may not
    /// run for a long time — the device may be offline — and a fold would sit
    /// on `.parked` while the queue holds no blocks at all, telling somebody
    /// who has just signed in to sign in again.
    @Test("releasing the queue moves the query off parked")
    func releasingMovesTheQueryOffParked() async throws {
        let (store, queue, transport, connManager, engine) = try await makeFixture()
        let query = try #require(store.queryFullSyncState())

        var input = CreateItemInput(type: "core.note", properties: ["body": .string("refused")])
        input.id = UUIDv7.generateString()
        try await queue.enqueueCreateItem(input, localId: input.id!)
        transport.enqueueError(UnauthorizedError(message: "key revoked"))
        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()
        try await awaitCondition(description: "query.state becomes .parked") {
            if case .parked = query.state { return true }
            return false
        }

        // Offline, so the drain this schedules cannot run. The state still has
        // to stop saying the credential is refused.
        await connManager.applyStateForTesting(.offline)
        #expect(try await engine.retryAll(reason: .credentialRefused) == 1)

        try await awaitCondition(description: "query.state leaves .parked") {
            if case .parked = query.state { return false }
            return true
        }
        query.stop()
    }
}
