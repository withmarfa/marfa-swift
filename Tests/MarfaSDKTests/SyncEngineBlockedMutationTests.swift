import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// A queued write that cannot succeed until the app changes something is
/// blocked rather than retried forever.
///
/// Before this, every such write was treated as a network blip: it was replayed
/// on every cycle, its attempt count climbed unread, and because it set the
/// cycle's error one stuck row made sync report failure permanently — so an app
/// showed a failure indicator that never cleared, beside a queue that was never
/// going to drain, and a genuine second failure was indistinguishable.
///
/// The tests assert what a consumer sees: the query's projection, the events,
/// the requests on the wire and the cycle's outcome.
///
/// Shared helpers live in ``SyncEngineTestKit``.
@Suite("A mutation that cannot proceed is blocked", .timeLimit(.minutes(1)))
struct SyncEngineBlockedMutationTests {

    // MARK: - Fixtures

    private func conflictResponse() -> ConflictResponse {
        ConflictResponse(
            ancestor: ConflictSnapshot(properties: ["body": .string("original")], version: 1),
            conflictingFields: ["body"],
            current: ConflictSnapshot(properties: ["body": .string("server edit")], version: 2),
            error: ConflictResponseError(code: .versionConflict, status: 409),
            mergePolicy: MergePolicy(default: .lastWriterWins, fields: nil)
        )
    }

    private func item(id: String, version: Int, body: String) -> Item {
        Item(
            createdAt: "2026-09-02T09:00:00Z", id: id,
            properties: ["body": .string(body)], schemaVersion: 1, source: "test",
            state: .active, tier: .feed, timestamp: "2026-09-02T09:00:00Z",
            type: "core.note", updatedAt: "2026-09-02T09:00:00Z", version: version
        )
    }

    /// The single queued record's summary, as `PendingMutationsQuery` would
    /// project it. Read through the same projection a consumer uses rather than
    /// through the raw row, so a test cannot pass on state the app never sees.
    private func summary(
        _ queue: MutationQueue,
        id: String? = nil
    ) async throws -> PendingMutationSummary {
        let records = try await queue.fetchAll()
        let record = try #require(
            id.map { wanted in records.first { $0.id == wanted } } ?? records.first
        )
        return PendingMutationSummary.make(from: record)
    }

    /// Accumulates events for as long as the test wants them.
    ///
    /// Deliberately not a task that returns on a terminal event: the engine
    /// under these tests is driven through the drain seam rather than started,
    /// so its event stream never finishes, and a collector awaiting an event
    /// that a regression stops emitting would hang instead of failing.
    private func probe(on engine: SyncEngine) async -> EventProbe {
        let probe = EventProbe()
        let events = await engine.events
        Task { for await event in events { await probe.record(event) } }
        return probe
    }

    // MARK: - resolverMissing

    @Test("a replay with no registered resolver blocks after one attempt")
    func missingResolverBlocksAfterOneAttempt() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let resolvers = ConflictResolverRegistry()
        let engine = SyncEngine(
            transport: transport, localStore: store, mutationQueue: queue,
            connectionManager: connManager, conflictResolvers: resolvers
        )

        let events = await probe(on: engine)

        try await queue.enqueueUpdateItem(
            id: "server-1", properties: ["body": .string("offline edit")],
            version: 1, conflict: .callback, tier: nil, sourceId: nil
        )

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // Blocked on the first failure. A second attempt could not differ, so
        // there is nothing to learn from making it.
        let blocked = try await summary(queue)
        if case let .blocked(reason, attemptCount, lastError) = blocked.status {
            #expect(reason == .resolverMissing)
            #expect(attemptCount == 1)
            // The message survives the encoding that carries the reason.
            #expect(lastError.contains("no resolver is registered"))
        } else {
            Issue.record("expected .blocked, got \(blocked.status)")
        }

        try await SyncEngineTestKit.awaitCondition(description: "a .mutationBlocked event to arrive") { await events.blocked.count == 1 }
        let blockedEvents = await events.blocked
        if case let .mutationBlocked(kind, itemId, reason) = blockedEvents.first {
            #expect(kind == "updateItem")
            #expect(itemId == "server-1")
            #expect(reason == .resolverMissing)
        } else {
            Issue.record("expected .mutationBlocked, got \(String(describing: blockedEvents.first))")
        }

        // The next drain does not ask the server anything about it.
        let callsBefore = transport.calls.count
        await engine.triggerProactiveDrainForTesting()
        #expect(transport.calls.count == callsBefore)
        #expect(try await queue.fetchAll().count == 1)
        // Once as it became blocked, not once per cycle. A bare count read here
        // races the detached task draining the event stream, so hold the window
        // open and prove a second never lands.
        try await SyncEngineTestKit.expectRemainsFalse(for: .milliseconds(200)) {
            await events.blocked.count > 1
        }
    }

    // MARK: - conflictUnresolved

    @Test("a manual conflict that outlives the loop blocks, and retry replays it")
    func manualConflictBlocksAndRetryReplaysIt() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport, localStore: store, mutationQueue: queue,
            connectionManager: connManager
        )

        try await queue.enqueueUpdateItem(
            id: "server-2", properties: ["body": .string("offline edit")],
            version: 1, conflict: .manual, tier: nil, sourceId: nil
        )
        transport.enqueue(conflictResponse())

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        let blocked = try await summary(queue)
        if case let .blocked(reason, attemptCount, _) = blocked.status {
            #expect(reason == .conflictUnresolved)
            #expect(attemptCount == 1)
        } else {
            Issue.record("expected .blocked(.conflictUnresolved), got \(blocked.status)")
        }

        // Skipped from here on, so the app is not sending the same refused
        // write on every cycle.
        let callsBefore = transport.calls.count
        await engine.triggerProactiveDrainForTesting()
        #expect(transport.calls.count == callsBefore)

        // The app resolves the conflict and asks for the write again.
        let id = try await #require(queue.fetchAll().first).id
        transport.enqueue(ItemResponse(item: item(id: "server-2", version: 3, body: "resolved")))
        try await engine.retry(id: id)
        await engine.triggerProactiveDrainForTesting()

        #expect(try await queue.isEmpty)
    }

    @Test("an unversioned update whose source id the server already holds blocks rather than looping")
    func sourceIdConflictOnUnversionedUpdateBlocks() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport, localStore: store, mutationQueue: queue,
            connectionManager: connManager
        )

        // No version, so this never reaches the conflict loop: it is a plain
        // PATCH, and the 409 comes back from the route rather than from a
        // version comparison. Nothing about it is resolvable by retrying — the
        // server holds that source id against a different row, and will answer
        // the same way forever.
        try await queue.enqueueUpdateItem(
            id: "server-3", properties: ["body": .string("imported edit")],
            version: nil, conflict: nil, tier: nil, sourceId: "upstream-42"
        )
        transport.enqueueError(
            ConflictError(message: "source_id already in use", details: nil)
        )

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        let blocked = try await summary(queue)
        if case let .blocked(reason, _, _) = blocked.status {
            #expect(reason == .conflictUnresolved)
        } else {
            Issue.record("expected .blocked(.conflictUnresolved), got \(blocked.status)")
        }

        let callsBefore = transport.calls.count
        await engine.triggerProactiveDrainForTesting()
        #expect(transport.calls.count == callsBefore)
    }

    // MARK: - The ceiling, and what is exempt from it

    @Test("a repeated non-network refusal blocks at the ceiling")
    func repeatedRefusalBlocksAtTheCeiling() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        // Two rather than the default five, so the ceiling under test is the
        // parameter rather than a constant the test would pass without.
        let engine = SyncEngine(
            transport: transport, localStore: store, mutationQueue: queue,
            connectionManager: connManager, maxReplayAttempts: 2
        )
        try await queue.enqueueDeleteItem(id: "server-teapot")
        await connManager.applyStateForTesting(.online)

        // 418 is outside the permanent set and outside the network class, so it
        // is the shape the ceiling exists for.
        transport.enqueueError(MarfaError(code: "teapot", message: "no", status: 418))
        await engine.triggerProactiveDrainForTesting()
        if case let .retrying(count, _) = try await summary(queue).status {
            #expect(count == 1)
        } else {
            Issue.record("expected .retrying on the first failure")
        }

        transport.enqueueError(MarfaError(code: "teapot", message: "no", status: 418))
        await engine.triggerProactiveDrainForTesting()

        let status = try await summary(queue).status
        if case let .blocked(reason, attemptCount, _) = status {
            #expect(reason == .retriesExhausted)
            #expect(attemptCount == 2)
        } else {
            Issue.record("expected .blocked(.retriesExhausted) at the ceiling, got \(status)")
        }
    }

    @Test("the cycle recovers from failed to synced when the last retry blocks")
    func retriesExhaustedDoesNotLeaveTheStateFailed() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport, localStore: store, mutationQueue: queue,
            connectionManager: connManager, maxReplayAttempts: 3
        )
        try await queue.enqueueDeleteItem(id: "server-teapot")
        await connManager.applyStateForTesting(.online)

        // Every attempt below the ceiling is an ordinary transient failure and
        // reports as one.
        for _ in 1...2 {
            transport.enqueueError(MarfaError(code: "teapot", message: "no", status: 418))
            await engine.triggerProactiveDrainForTesting()
            if case .failed = await engine.fullSyncState { } else {
                Issue.record("expected .failed below the ceiling")
            }
        }

        // The attempt that blocks has to clear it. A clean drain is the only
        // thing that resets `lastFailedError`, so if the blocking cycle does not
        // record one, the failure from the attempt before it stands forever.
        transport.enqueueError(MarfaError(code: "teapot", message: "no", status: 418))
        await engine.triggerProactiveDrainForTesting()

        if case .synced = await engine.fullSyncState { } else {
            Issue.record("expected .synced once the row blocked; got \(await engine.fullSyncState)")
        }
    }

    @Test("network-class failures never block, however far the attempt count climbs")
    func networkClassNeverBlocks() async throws {
        // Each is a statement about the environment rather than about the
        // write, and each clears without the app doing anything. Blocking a
        // valid write behind an outage would be the worse defect.
        let failures: [(String, Error)] = [
            ("offline", NetworkError(NSError(domain: "t", code: 0, userInfo: [NSLocalizedDescriptionKey: "offline"]))),
            ("503", MarfaError(code: "unavailable", message: "down", status: 503)),
            ("429", MarfaError(code: "rate_limited", message: "slow down", status: 429)),
            ("401", MarfaError(code: "unauthorized", message: "stale token", status: 401)),
            // Reached in production wherever the transport translates a
            // cancelled URLSession task. `stop()` cancels an in-flight replay,
            // and the throw lands in the same catch, so without the exemption a
            // handful of ordinary app backgrounds would block a write nothing
            // had refused.
            ("cancelled", CancellationError()),
        ]

        for (label, failure) in failures {
            let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
            try await SyncEngineTestKit.markImported(queue)
            let transport = MockTransport()
            let connManager = ConnectionStateManager()
            let engine = SyncEngine(
                transport: transport, localStore: store, mutationQueue: queue,
                connectionManager: connManager
            )
            try await queue.enqueueDeleteItem(id: "server-\(label)")
            await connManager.applyStateForTesting(.online)

            // Two past the ceiling.
            for _ in 1...7 {
                transport.enqueueError(failure)
                await engine.triggerProactiveDrainForTesting()
            }

            let status = try await summary(queue).status
            if case let .retrying(attemptCount, _) = status {
                #expect(attemptCount == 7, "\(label): the count should keep climbing")
            } else {
                Issue.record("\(label): expected .retrying past the ceiling, got \(status)")
            }
        }
    }

    // MARK: - The cycle's outcome

    @Test("a blocked row does not fail the cycle, and a healthy row beside it still syncs")
    func blockedRowDoesNotFailTheCycle() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let resolvers = ConflictResolverRegistry()
        let engine = SyncEngine(
            transport: transport, localStore: store, mutationQueue: queue,
            connectionManager: connManager, conflictResolvers: resolvers
        )

        // Cycle one blocks the callback update.
        try await queue.enqueueUpdateItem(
            id: "server-blocked", properties: ["body": .string("edit")],
            version: 1, conflict: .callback, tier: nil, sourceId: nil
        )
        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // Cycle two: an unrelated write that the server accepts.
        try await queue.enqueueDeleteItem(id: "server-healthy")
        transport.enqueue(EmptyResponse())

        let events = await probe(on: engine)
        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        try await SyncEngineTestKit.awaitCondition(description: "the cycle to report .synced") { await events.contains { if case .synced = $0 { return true } else { return false } } }
        #expect(await !events.contains { if case .failed = $0 { return true } else { return false } })

        // And the state the app renders agrees.
        if case .synced = await engine.fullSyncState { } else {
            Issue.record("expected .synced; got \(await engine.fullSyncState)")
        }

        // The healthy write went; the blocked one stayed.
        let remaining = try await queue.fetchAll()
        #expect(remaining.count == 1)
        #expect(remaining.first?.localId == "server-blocked")
        // It is still unsent work, so the queue still says so — a blocked row
        // is skipped by the drain, not forgotten by the app.
        #expect(try await engine.hasPendingMutations)
    }

    @Test("retry clears the block and resets the count")
    func retryClearsTheBlock() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport, localStore: store, mutationQueue: queue,
            connectionManager: connManager
        )
        try await queue.enqueueDeleteItem(id: "server-teapot")
        await connManager.applyStateForTesting(.online)

        for _ in 1...5 {
            transport.enqueueError(MarfaError(code: "teapot", message: "no", status: 418))
            await engine.triggerProactiveDrainForTesting()
        }
        let id = try await #require(queue.fetchAll().first).id

        try await engine.retry(id: id)
        let afterRetry = try await summary(queue).status
        #expect(afterRetry == .pending, "the block and the count both go")

        transport.enqueue(EmptyResponse())
        await engine.triggerProactiveDrainForTesting()
        #expect(try await queue.isEmpty)
    }

    // MARK: - Ordering

    @Test("a blocked row holds back later writes to the same item and nothing else")
    func blockedRowDefersOnlyItsOwnItem() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let resolvers = ConflictResolverRegistry()
        let engine = SyncEngine(
            transport: transport, localStore: store, mutationQueue: queue,
            connectionManager: connManager, conflictResolvers: resolvers
        )

        // Blocked first, then a later edit to the same item, then an unrelated
        // one. The queue drains in creation order.
        try await queue.enqueueUpdateItem(
            id: "server-a", properties: ["body": .string("first")],
            version: 1, conflict: .callback, tier: nil, sourceId: nil
        )
        try await queue.enqueueUpdateItem(id: "server-a", properties: ["body": .string("second")])
        try await queue.enqueueUpdateItem(id: "server-b", properties: ["body": .string("unrelated")])

        transport.enqueue(ItemResponse(item: item(id: "server-b", version: 2, body: "unrelated")))

        let events = await probe(on: engine)
        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        let patched = transport.calls.filter { $0.method == .patch }.map(\.path)
        // The unrelated item goes. Holding the whole queue behind one blocked
        // row would reproduce the defect this change exists to fix, one level up.
        #expect(patched.contains("/items/server-b"))
        // The later edit to the blocked item does not, because applying it over
        // an earlier edit that has not landed would reorder the two and lose
        // whatever the first one was carrying.
        #expect(!patched.contains("/items/server-a"))

        let remaining = try await queue.fetchAll()
        #expect(remaining.count == 2)
        #expect(remaining.allSatisfy { $0.localId == "server-a" })

        // And the cycle is clean. A row held back behind a block is not work
        // the cycle failed to do, so it must not withhold `.synced` — deciding
        // that from a count of the queue instead is what left this shape, the
        // common one, never reporting a successful sync again.
        try await SyncEngineTestKit.awaitCondition(description: "the cycle to report .synced with a deferred row outstanding") { await events.contains { if case .synced = $0 { return true } else { return false } } }
        #expect(await !events.contains { if case .failed = $0 { return true } else { return false } })
    }

    @Test("a write queued before the blocked one for the same item keeps being attempted")
    func rowQueuedBeforeTheBlockIsNotDeferred() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport, localStore: store, mutationQueue: queue,
            connectionManager: connManager, maxReplayAttempts: 2
        )

        // Two writes to one item. The earlier is taking 503s; the later will
        // block at the ceiling. Only writes queued *after* the block are out of
        // order with it, so the earlier one must keep going — deferring it too
        // would strand it forever while still projecting `.retrying` on a count
        // that never moves again.
        try await queue.enqueueUpdateItem(id: "server-a", properties: ["body": .string("first")])
        // Distinct timestamps on purpose. `createdAt` has millisecond
        // resolution and the cut-off comparison is `>=`, so two writes made
        // inside one millisecond tie and the earlier one waits behind the
        // block — deliberate, since ordering matters more than liveness there.
        // This test is about a write that is genuinely earlier, so it has to be
        // measurably earlier.
        try await Task.sleep(for: .milliseconds(5))
        try await queue.enqueueUpdateItem(id: "server-a", properties: ["body": .string("second")])
        let ids = try await queue.fetchAll().map(\.id)
        await connManager.applyStateForTesting(.online)

        // Cycle one: both fail. Cycle two: the first still 503s, the second
        // reaches the ceiling and blocks.
        for _ in 1...2 {
            transport.enqueueError(MarfaError(code: "unavailable", message: "down", status: 503))
            transport.enqueueError(MarfaError(code: "teapot", message: "no", status: 418))
            await engine.triggerProactiveDrainForTesting()
        }

        let later = try await summary(queue, id: ids[1]).status
        if case let .blocked(reason, _, _) = later {
            #expect(reason == .retriesExhausted)
        } else {
            Issue.record("expected the later write to block, got \(later)")
        }

        // The earlier one is still being sent, and its count is still moving.
        let callsBefore = transport.calls.count
        transport.enqueueError(MarfaError(code: "unavailable", message: "down", status: 503))
        await engine.triggerProactiveDrainForTesting()
        #expect(transport.calls.count > callsBefore)

        if case let .retrying(attemptCount, _) = try await summary(queue, id: ids[0]).status {
            #expect(attemptCount == 3)
        } else {
            Issue.record("expected the earlier write to still be retrying")
        }
    }

    // MARK: - A queue of nothing but blocked rows

    @Test("a queue holding only blocked rows does not open a cycle")
    func onlyBlockedRowsWithholdSyncing() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let resolvers = ConflictResolverRegistry()
        let engine = SyncEngine(
            transport: transport, localStore: store, mutationQueue: queue,
            connectionManager: connManager, conflictResolvers: resolvers
        )

        try await queue.enqueueUpdateItem(
            id: "server-1", properties: ["body": .string("edit")],
            version: 1, conflict: .callback, tier: nil, sourceId: nil
        )
        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // From here the queue holds one row and the drain will attempt none of
        // it. Entering a cycle anyway would emit `.syncing`, walk the row, skip
        // it and do the same next time — a device flapping through a syncing
        // state forever over a write the engine has stopped asking about.
        let events = await probe(on: engine)
        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        try await SyncEngineTestKit.expectRemainsFalse(for: .milliseconds(200)) {
            await events.contains { if case .syncing = $0 { return true } else { return false } }
        }
    }

    // MARK: - Across cycles

    @Test("a block laid down in one cycle defers a write queued for that item in the next")
    func blockDefersAWriteQueuedInALaterCycle() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let resolvers = ConflictResolverRegistry()
        let engine = SyncEngine(
            transport: transport, localStore: store, mutationQueue: queue,
            connectionManager: connManager, conflictResolvers: resolvers
        )

        try await queue.enqueueUpdateItem(
            id: "server-a", properties: ["body": .string("first")],
            version: 1, conflict: .callback, tier: nil, sourceId: nil
        )
        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // The block is now on disk and nothing stops in the cycle below, so the
        // in-cycle set is empty there. Only the cut-off carried out of the
        // partition can hold this write back — which is what makes this the
        // test that fails if that cut-off is dropped.
        try await queue.enqueueUpdateItem(id: "server-a", properties: ["body": .string("second")])
        let callsBefore = transport.calls.count
        await engine.triggerProactiveDrainForTesting()

        #expect(transport.calls.count == callsBefore)
        #expect(try await queue.fetchAll().count == 2)
    }

    @Test("a callback resolver the server keeps refusing blocks as conflictUnresolved")
    func decliningCallbackResolverBlocks() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let resolvers = ConflictResolverRegistry()
        // Hands back the same properties every time, so the server has no
        // reason to stop answering 409 and the loop runs out of retries. This
        // is the "declining callback" route, as distinct from `.manual`.
        await resolvers.register { _ in ["body": .string("mine")] }
        let engine = SyncEngine(
            transport: transport, localStore: store, mutationQueue: queue,
            connectionManager: connManager, conflictResolvers: resolvers
        )

        try await queue.enqueueUpdateItem(
            id: "server-c", properties: ["body": .string("mine")],
            version: 1, conflict: .callback, tier: nil, sourceId: nil
        )
        // One more than the conflict loop will retry, so it exhausts rather
        // than succeeding on the last pass.
        for _ in 0...3 { transport.enqueue(conflictResponse()) }

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        if case let .blocked(reason, _, _) = try await summary(queue).status {
            #expect(reason == .conflictUnresolved)
        } else {
            Issue.record("expected .blocked(.conflictUnresolved) after the resolver was refused")
        }
    }

    // MARK: - Asking for a drain

    @Test("clearing a block emits a drain request")
    func clearingABlockAsksForADrain() async throws {
        let (_, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await queue.enqueueDeleteItem(id: "server-x")
        let id = try #require(await queue.fetchAll().first).id
        try await queue.recordBlocked(id: id, reason: .retriesExhausted, error: "no")

        // Subscribe before the call: the stream registers synchronously with
        // the access, so a ping cannot land in the gap.
        let requests = await queue.drainRequests
        let heard = Task { for await _ in requests { return true }; return false }

        try await queue.clearBlock(id: id)
        #expect(await heard.value, "clearBlock must ask for a drain, not just change a column")
    }

    @Test("a retry during a running cycle replays without another trigger")
    func retryDuringACycleReplaysOnItsOwn() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let transport = HoldsFirstReplayTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport, localStore: store, mutationQueue: queue,
            connectionManager: connManager
        )

        // One row already blocked, and one the transport holds open so a cycle
        // is demonstrably in flight when `retry` is called.
        try await queue.enqueueDeleteItem(id: "server-blocked")
        let blockedId = try #require(await queue.fetchAll().first).id
        try await queue.recordBlocked(id: blockedId, reason: .retriesExhausted, error: "no")
        try await queue.enqueueDeleteItem(id: "server-slow")

        await connManager.applyStateForTesting(.online)
        // Driven through the seam rather than by starting the engine: a started
        // engine reconnects and drains again on its own, which would replay the
        // retried row whether or not the request made during the cycle was
        // kept. Here the second pass has exactly one possible cause.
        let cycle = Task { await engine.triggerProactiveDrainForTesting() }
        try await SyncEngineTestKit.awaitCondition(description: "the held replay to start") { await transport.requestStarted }

        // Before this, the overlap guard dropped a request arriving mid-cycle,
        // so the row waited for an unrelated wake-up — which against a live
        // server, where the stream stays open, may never come.
        try await engine.retry(id: blockedId)
        await transport.release()
        await cycle.value

        #expect(try await queue.isEmpty, "the retried row should replay on the pass that follows")
    }

    // MARK: - Persistence

    @Test("a blocked row survives the store being closed and reopened")
    func blockedStateRoundTripsThroughDisk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("marfa-blocked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("store.sqlite").path

        let id: String
        do {
            let container = try MarfaModelContainer.make(path: path)
            let queue = await Task.detached { MutationQueue(modelContainer: container) }.value
            try await queue.enqueueDeleteItem(id: "server-x")
            id = try #require(await queue.fetchAll().first).id
            try await queue.recordBlocked(
                id: id, reason: .conflictUnresolved, error: "code=version_conflict status=409"
            )
        }

        // A fresh container over the same file, as a relaunch would build. The
        // state is a raw value in an existing column and the reason rides in
        // the message beside it, so both have to survive a round trip through
        // SQLite rather than only through one process's memory.
        let reopened = try MarfaModelContainer.make(path: path)
        let queue = await Task.detached { MutationQueue(modelContainer: reopened) }.value
        let record = try #require(await queue.fetchAll().first)
        #expect(record.id == id)

        if case let .blocked(reason, attemptCount, lastError) =
            PendingMutationSummary.make(from: record).status {
            #expect(reason == .conflictUnresolved)
            #expect(attemptCount == 1)
            // Stripped on the way out: the prefix is storage, not a message.
            #expect(lastError == "code=version_conflict status=409")
        } else {
            Issue.record("expected .blocked after reopening the store")
        }
    }
}

/// Holds the first replay request open until the test releases it, then lets
/// everything through. Lets a test stand inside a running drain cycle.
private actor HoldsFirstReplayTransport: Transport {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requestStarted = false
    private var held = false

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func request<T: Decodable & Sendable>(
        method: HTTPMethod, path: String,
        body: (any Encodable & Sendable)?, query: [(String, String)]?
    ) async throws -> T {
        if !held {
            held = true
            requestStarted = true
            await withCheckedContinuation { self.continuation = $0 }
        }
        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(EmptyResponse()))
    }

    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod, path: String,
        body: (any Encodable & Sendable)?, query: [(String, String)]?
    ) async throws -> ConflictResult<T> {
        .success(try await request(method: method, path: path, body: body, query: query))
    }

    func rawRequest(
        method: HTTPMethod, path: String, body: Data?,
        contentType: String?, query: [(String, String)]?
    ) async throws -> (Data, HTTPURLResponse) {
        fatalError("HoldsFirstReplayTransport: rawRequest not supported")
    }

    nonisolated func eventStream(
        path: String, query: [(String, String)]?, lastEventID: String?
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Accumulates the engine's events so a test can read them at any point,
/// rather than awaiting a terminator that a regression may never send.
private actor EventProbe {
    private var events: [SyncEvent] = []
    func record(_ event: SyncEvent) { events.append(event) }
    var all: [SyncEvent] { events }
    var blocked: [SyncEvent] {
        events.filter { if case .mutationBlocked = $0 { return true } else { return false } }
    }
    func contains(_ predicate: (SyncEvent) -> Bool) -> Bool { events.contains(where: predicate) }
}
