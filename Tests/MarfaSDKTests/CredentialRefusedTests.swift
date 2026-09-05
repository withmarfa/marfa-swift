import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// **A refusal the queue used to retry for ever.**
///
/// The contract's failure table puts a `401` — one the transport's single
/// refresh did not clear — in a class of its own: park the whole queue, say so,
/// and drop nothing. The kit classed it environmental instead, alongside a
/// `5xx` and a dropped connection, on the reasoning that everything in that
/// class clears without the app doing anything.
///
/// That reasoning holds for a network and does not hold for a credential. A
/// revoked key answers `401` for ever, so the queue spun, and an app could show
/// only a count of unsent writes that never moved — with nothing anywhere
/// saying that a person had to sign in again.
@Suite("A refused credential parks the queue", .timeLimit(.minutes(1)))
struct CredentialRefusedTests {

    private func queueThree(_ queue: MutationQueue) async throws {
        for label in ["one", "two", "three"] {
            var input = CreateItemInput(type: "core.note", properties: ["body": .string(label)])
            input.id = UUIDv7.generateString()
            try await queue.enqueueCreateItem(input, localId: input.id!)
        }
    }

    @Test("a 401 parks every queued write rather than retrying it")
    func aRefusedCredentialParksTheWholeQueue() async throws {
        let (_, queue, transport, manager, engine) = try await SyncEngineTestKit.makeFixture()
        try await queueThree(queue)

        // One refusal, not three: the first row's answer settles the rest.
        transport.enqueueError(UnauthorizedError(message: "key revoked"))

        await manager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        let counts = try await queue.counts
        #expect(counts.pending == 0, "nothing is still waiting to be tried")
        #expect(counts.inFlight == 0)
        #expect(
            counts.blocked[.credentialRefused] == 3,
            "all three park together: \(counts.blocked)"
        )
        #expect(counts.deadLettered == 0, "parked, not dropped")

        // And only one request was spent learning it.
        let writes = transport.calls.filter { $0.method == .post && $0.path == "/items" }
        #expect(writes.count == 1, "sent \(writes.count) writes to learn one answer")
    }

    @Test("the parking is announced, with how many it took")
    func theParkingIsAnnounced() async throws {
        let (_, queue, transport, manager, engine) = try await SyncEngineTestKit.makeFixture()
        try await queueThree(queue)
        transport.enqueueError(UnauthorizedError(message: "key revoked"))

        let events = engine.events
        let seen = ParkBox()
        let watcher = Task {
            for await event in events {
                if case .queueParked(let reason, let count) = event {
                    await seen.add(reason: reason, count: count)
                }
            }
        }
        defer { watcher.cancel() }

        await manager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        try await SyncEngineTestKit.awaitCondition(description: "a queueParked event") {
            await seen.parks.count >= 1
        }
        let parks = await seen.parks
        #expect(parks.count == 1, "one announcement per parking, not one per row")
        #expect(parks.first?.reason == .credentialRefused)
        #expect(parks.first?.count == 3, "the count is every write parked, not the rest")
    }

    @Test("a refusal about the credential does not spend the retry ceiling")
    func itParksOnTheFirstRefusalRatherThanTheFifth() async throws {
        let (_, queue, transport, manager, engine) = try await SyncEngineTestKit.makeFixture()
        var input = CreateItemInput(type: "core.note", properties: ["body": .string("only")])
        input.id = UUIDv7.generateString()
        try await queue.enqueueCreateItem(input, localId: input.id!)

        transport.enqueueError(UnauthorizedError(message: "key revoked"))
        await manager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        let row = try #require(try await queue.fetchAll().first)
        #expect(row.state == .blocked)
        #expect(row.blockedReason == .credentialRefused, "not retries exhausted, which names the wrong cause")
        #expect(row.refusalCount == 0, "the ceiling is for refusals of the write, not of the key")
    }

    /// **Release by reason, because a new credential settles nothing else.** A
    /// conflict awaiting review is not resolved by signing in again, and
    /// sweeping it up would tell an app it was moving when nothing had changed
    /// for it.
    @Test("releasing the credential class leaves other parked work alone")
    func releasingOneReasonLeavesTheOthers() async throws {
        let (_, queue, transport, manager, engine) = try await SyncEngineTestKit.makeFixture()
        try await queueThree(queue)

        let rows = try await queue.fetchAll()
        try await queue.recordBlocked(
            id: rows[2].id,
            reason: PendingMutationBlockReason.conflictUnresolved,
            error: "somebody has to settle this"
        )

        transport.enqueueError(UnauthorizedError(message: "key revoked"))
        await manager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        let parked = try await queue.counts
        #expect(parked.blocked[.credentialRefused] == 2)
        #expect(parked.blocked[.conflictUnresolved] == 1, "the conflict keeps its own reason")

        let released = try await engine.retryAll(reason: .credentialRefused)
        #expect(released == 2)

        let after = try await queue.counts
        #expect(after.pending == 2, "the two on the credential are sendable again")
        #expect(after.blocked[.credentialRefused] == nil)
        #expect(after.blocked[.conflictUnresolved] == 1, "still waiting for a person")
    }

    /// A key answered for a different body cannot be replayed into a different
    /// answer, so repeating it four more times is four guaranteed refusals and
    /// then a reason naming the wrong cause.
    @Test("a spent idempotency key parks on the first refusal")
    func aSpentKeyParksImmediately() async throws {
        let (_, queue, transport, manager, engine) = try await SyncEngineTestKit.makeFixture()
        var input = CreateItemInput(type: "core.note", properties: ["body": .string("only")])
        input.id = UUIDv7.generateString()
        try await queue.enqueueCreateItem(input, localId: input.id!)

        // **The literal, not the constant.** Production matches on
        // `MarfaError.idempotencyKeyReusedCode`, so building the error from it
        // too would let its value drift away from the server's while the suite
        // stayed green and the kit stopped recognizing the refusal.
        #expect(MarfaError.idempotencyKeyReusedCode == "idempotency_key_reused")
        transport.enqueueError(MarfaError(
            code: "idempotency_key_reused",
            message: "that key already answered a different body",
            status: 422
        ))
        await manager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        let row = try #require(try await queue.fetchAll().first)
        #expect(row.blockedReason == .idempotencyKeyReused)
        #expect(row.refusalCount == 0, "the ceiling is not spent on a refusal that cannot change")

        let writes = transport.calls.filter { $0.method == .post && $0.path == "/items" }
        #expect(writes.count == 1, "sent \(writes.count) times; the key is spent, not the write")
    }

    /// The environmental class is unchanged for everything that really does
    /// clear on its own, which is what stops this fix stranding a valid write
    /// behind an outage.
    @Test("a 500 and a suspended space still ride it out")
    func theEnvironmentalClassIsUnchanged() async throws {
        #expect(
            PendingMutationBlockReason.classify(
                error: MarfaError(code: "server_error", message: "boom", status: 500),
                kind: .createItem, refusalCount: 0, ceiling: 5
            ) == nil
        )
        #expect(
            PendingMutationBlockReason.classify(
                error: MarfaError(
                    code: MarfaError.spaceSuspendedCode, message: "paused", status: 403
                ),
                kind: .createItem, refusalCount: 0, ceiling: 5
            ) == nil
        )
        #expect(
            PendingMutationBlockReason.classify(
                error: NetworkError(URLError(.notConnectedToInternet)),
                kind: .createItem, refusalCount: 0, ceiling: 5
            ) == nil
        )
        // The other two the changelog names in the same sentence. Both are
        // covered through the engine by `networkClassNeverBlocks`; this is the
        // test that reads as the guard for the claim, so it should carry them.
        #expect(
            PendingMutationBlockReason.classify(
                error: MarfaError(code: "rate_limited", message: "slow down", status: 429),
                kind: .createItem, refusalCount: 0, ceiling: 5
            ) == nil
        )
        #expect(
            PendingMutationBlockReason.classify(
                error: CancellationError(),
                kind: .createItem, refusalCount: 0, ceiling: 5
            ) == nil
        )
    }

    /// **A parked queue is not a drained one, and this is the assertion that
    /// says so.** The clean-drain decision ignores blocked rows on purpose — a
    /// row stopped for a stated reason is not work the cycle failed to do —
    /// and it was written when blocking was per-row and rare. Parking every
    /// row at once makes "nothing outstanding" true for the worst possible
    /// reason, so the pass stamped a clean drain and published `.synced`: a
    /// green tick and "synced just now" over a queue that cannot move until
    /// somebody signs in again. Louder than the defect it replaced.
    @Test("a parked queue is not reported as synced")
    func parkingIsNotACleanDrain() async throws {
        let (_, queue, transport, manager, engine) = try await SyncEngineTestKit.makeFixture()
        try await queueThree(queue)
        transport.enqueueError(UnauthorizedError(message: "key revoked"))

        await manager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        #expect(
            await engine.lastCleanDrainAt == nil,
            "the queue never drained; nothing should have been stamped"
        )
        if case .synced = await engine.fullSyncState {
            Issue.record("reported .synced over a queue parked on a dead credential")
        }
    }

    /// **Releasing is not sending.** `retryAll` returned a count and left the
    /// rows sitting `.pending` until something unrelated woke the engine —
    /// which used to be the two-minute stream close and is not any more. The
    /// method's name promises the send, so it has to ask for one, exactly as
    /// `retry(id:)` does.
    ///
    /// **Asserted on the ask rather than on the send, and the first version of
    /// this was vanity for want of that.** Driven against a live engine it
    /// waited for a write to go out, and a write went out with both asks
    /// removed — a second later, by some other path, which no assertion
    /// without a clock in it could tell from the one this is about. The drain
    /// request is the mechanism, and it is observable.
    @Test("releasing the queue asks for a drain")
    func releasingAsksForADrain() async throws {
        let (_, queue, _, _, _) = try await SyncEngineTestKit.makeFixture()
        try await queueThree(queue)
        let rows = try await queue.fetchAll()
        for row in rows {
            try await queue.recordBlocked(
                id: row.id, reason: .credentialRefused, error: "key revoked"
            )
        }

        let requests = await queue.drainRequests
        let asked = AskBox()
        let watcher = Task {
            for await _ in requests { await asked.count() }
        }
        defer { watcher.cancel() }

        #expect(try await queue.retryAll(reason: .credentialRefused) == 3)

        try await SyncEngineTestKit.awaitCondition(description: "a drain request") {
            await asked.asks >= 1
        }
        #expect(await asked.asks == 1, "one ask for the release, not one per row")
    }

    /// And the engine's own half, which covers the condition the queue's ping
    /// does not: a cycle already running has no idle listener to wake, so the
    /// request has to be taken by the pass that follows it.
    @Test("releasing during a cycle is taken by the next pass")
    func releasingDuringACycleIsTakenByTheNextPass() async throws {
        let (_, queue, transport, manager, engine) = try await SyncEngineTestKit.makeFixture()
        try await queueThree(queue)
        transport.enqueueError(UnauthorizedError(message: "key revoked"))
        await manager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()
        #expect(try await queue.counts.blocked[.credentialRefused] == 3)

        let before = transport.calls.filter { $0.method == .post && $0.path == "/items" }.count
        #expect(try await engine.retryAll(reason: .credentialRefused) == 3)
        await engine.triggerProactiveDrainForTesting()

        let after = transport.calls.filter { $0.method == .post && $0.path == "/items" }.count
        #expect(after > before, "the released rows were never attempted again")
    }

    /// A row left `.inFlight` by a process that died mid-send is live work, and
    /// parks with the rest. Nothing else resets one on load, and the replay
    /// re-admits it, so leaving it out would send it to be refused alone.
    @Test("a row left in flight parks with the rest")
    func anInFlightRowParksToo() async throws {
        let (_, queue, transport, manager, engine) = try await SyncEngineTestKit.makeFixture()
        try await queueThree(queue)
        let rows = try await queue.fetchAll()
        try await queue.markInFlight(id: rows[2].id)

        transport.enqueueError(UnauthorizedError(message: "key revoked"))
        await manager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        let counts = try await queue.counts
        #expect(counts.inFlight == 0, "a row left in flight was not parked")
        #expect(counts.blocked[.credentialRefused] == 3)
    }
}

private actor AskBox {
    private(set) var asks = 0
    func count() { asks += 1 }
}

private actor ParkBox {
    private(set) var parks: [(reason: PendingMutationBlockReason, count: Int)] = []
    func add(reason: PendingMutationBlockReason, count: Int) { parks.append((reason, count)) }
}