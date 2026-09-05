import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// The retry ceiling counts refusals, not attempts nobody could make.
///
/// A ceiling exists to stop retrying something that will never succeed. An
/// attempt that failed because there was no network says nothing about
/// whether the write will succeed — it says the question was never asked.
/// Counting it conflates *we could not ask* with *we asked and were refused*.
///
/// **Not an edge case.** A device offline for a week exhausts its budget
/// having learned nothing, then blocks on the first real answer it ever
/// receives. That is what a commute looks like.
@Suite("The ceiling counts refusals", .timeLimit(.minutes(1)))
struct RetryCeilingTests {

    private func offline() -> MarfaError { NetworkError(URLError(.notConnectedToInternet)) }
    private func refusal() -> MarfaError {
        MarfaError(code: "teapot", message: "no", status: 418)
    }

    /// The two quantities, and the reason they need separate columns: after a
    /// week offline the displayed count is honest and the ceiling's is zero.
    @Test("an outage raises what a person sees and not what the ceiling reads")
    func anOutageRaisesOnlyTheDisplayedCount() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueueEvents([])
        await engine.start()

        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        let item = try await store.createItem(input)
        try await queue.enqueueCreateItem(input, localId: item.id)

        // **Flooded rather than one-per-drain.** A started engine drains on
        // its own as well, so a loop that enqueues one error per explicit
        // replay leaves a background drain finding an empty response queue —
        // and a missing-mock error is not a network error, so it counts as a
        // refusal and the assertion below sees a 1 it cannot explain.
        for _ in 0..<40 { transport.enqueueError(offline()) }
        for _ in 0..<8 { await engine.replayMutationsForTesting() }
        try await SyncEngineTestKit.awaitCondition(description: "the outage was felt") {
            try await queue.fetchAll().first?.attemptCount ?? 0 >= 8
        }

        let row = try #require(await queue.fetchAll().first)
        // Only this one. `attemptCount >= 8` restated the condition just
        // awaited, on a quantity nothing decrements, and `state != .blocked`
        // cannot fail — every path that blocks starves the wait above first.
        #expect(row.refusalCount == 0, "nothing refused it; nothing was ever asked")
        await engine.stop()
    }

    /// The consequence the ruling is about. With one counter the outage above
    /// would have spent the budget, so this refusal — the first real answer
    /// the device ever received — would block on its first attempt.
    @Test("a real refusal after a long outage still gets its full allowance")
    func aRefusalAfterAnOutageGetsItsAllowance() {
        let ceiling = 5

        // A row that has been offline a thousand times and refused none.
        #expect(PendingMutationBlockReason.classify(
            error: refusal(), kind: .createItem, refusalCount: 0, ceiling: ceiling
        ) == nil, "the first refusal must not be the last")

        // And the ceiling still holds on refusals, so the assertion above is
        // about which number is counted rather than about the ceiling having
        // stopped working.
        #expect(PendingMutationBlockReason.classify(
            error: refusal(), kind: .createItem, refusalCount: ceiling - 1, ceiling: ceiling
        ) == .retriesExhausted)
    }

    /// End to end: refusals accumulate and the row blocks, so the separation
    /// has not simply switched the ceiling off.
    @Test("refusals still exhaust the ceiling")
    func refusalsStillBlock() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueueEvents([])
        await engine.start()

        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        let item = try await store.createItem(input)
        try await queue.enqueueCreateItem(input, localId: item.id)

        for _ in 0..<40 { transport.enqueueError(refusal()) }
        for _ in 0..<6 { await engine.replayMutationsForTesting() }
        try await SyncEngineTestKit.awaitCondition(description: "the row blocked") {
            try await queue.fetchAll().first?.state == .blocked
        }

        let row = try #require(await queue.fetchAll().first)
        #expect(row.blockedReason == .retriesExhausted)
        // Exact, not `> 0`. The ceiling is five and `classify` counts the
        // refusal in hand alongside the four recorded, so a blocked row has
        // recorded exactly one fewer than the ceiling. `> 0` survived four
        // separate mutations.
        #expect(row.refusalCount == 4)
        await engine.stop()
    }

    /// Retrying resets both, because a person asking for another go means
    /// both questions start again.
    @Test("retrying clears both counters")
    func retryClearsBoth() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueueEvents([])
        await engine.start()

        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        let item = try await store.createItem(input)
        try await queue.enqueueCreateItem(input, localId: item.id)
        let id = try #require(await queue.fetchAll().first?.id)

        transport.enqueueError(refusal())
        await engine.replayMutationsForTesting()
        try await SyncEngineTestKit.awaitCondition(description: "a refusal landed") {
            try await queue.fetchAll().first?.refusalCount ?? 0 > 0
        }

        try await queue.clearBlock(id: id)
        let row = try #require(await queue.fetchAll().first)
        #expect(row.attemptCount == 0)
        #expect(row.refusalCount == 0)
        await engine.stop()
    }

    // MARK: - The class the transport never sees

    /// A store failure during replay is not a refusal, and a review found it
    /// counted as one.
    ///
    /// **The replay writes to the store *after* a `2xx`** — it adopts the row
    /// the server returned — so a store that refuses there is a write the
    /// server accepted. Counting that spends the budget on an answer that was
    /// yes, and a store failing for its own environmental reason, a locked
    /// device or a full disk, spends all of it: the row ends blocked as
    /// "ran out of retries" for a write the server already holds, and every
    /// later write to that item stalls behind it.
    ///
    /// `isEnvironmental` cannot see this class, because it is transport-shaped
    /// and a `LocalStoreError` never reaches a transport. `isServerRefusal` is
    /// the narrower question the ceiling actually asks.
    @Test("a store failure is not a refusal the server made")
    func aStoreFailureIsNotARefusal() {
        let storeFailure = LocalStoreError.databaseSetupFailed("disk is full")
        #expect(PendingMutationBlockReason.isServerRefusal(storeFailure) == false)

        // The discriminators, both directions. A real refusal counts, and an
        // environmental one does not — so the assertion above is about the
        // error's origin rather than about the ceiling having stopped
        // counting anything.
        #expect(PendingMutationBlockReason.isServerRefusal(refusal()))
        #expect(PendingMutationBlockReason.isServerRefusal(offline()) == false)
    }

    /// A response the server sent and the kit could not read *is* a refusal:
    /// the question was asked and answered, and repeating it will produce the
    /// same unreadable answer.
    @Test("an unreadable response still counts, because the server answered")
    func anUndecodableResponseIsARefusal() {
        struct Boom: Error {}
        #expect(PendingMutationBlockReason.isServerRefusal(ResponseDecodingError(Boom())))
    }

    // MARK: - The sequence the rest of this suite could not see

    /// **The defect this whole change exists to fix, and nothing else here
    /// catches it.**
    ///
    /// A review found that reverting the call site to the pre-change wiring —
    /// handing `classify` the attempt count instead of the refusal count —
    /// left every other test in this suite green. The reason is that
    /// `classify` returns `nil` for an environmental failure *before* it
    /// reaches the ceiling, so during a pure outage the ceiling is never
    /// consulted and both versions behave identically. The difference only
    /// appears when an outage is followed by a real refusal, and no test ran
    /// that sequence through the engine.
    ///
    /// So this is the regression guard the suite claimed to be and was not.
    @Test("an outage does not spend the allowance a later refusal needs")
    func anOutageDoesNotSpendTheAllowance() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()

        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        let item = try await store.createItem(input)
        try await queue.enqueueCreateItem(input, localId: item.id)
        let id = try #require(await queue.fetchAll().first?.id)

        // **The engine is started after the outage, not before it.** Enqueuing
        // emits a drain request, so a started engine begins draining while the
        // sequence below is still being written — and a drain that finds no
        // queued response gets an error that counts as a refusal, which is
        // the one number this test is about. Nothing drains until there is an
        // engine, so writing the history first makes it exact.
        //
        // A week offline, recorded directly so the sequence is the test's
        // rather than at the mercy of how often a started engine chose to try.
        for _ in 0..<20 {
            try await queue.recordFailure(
                id: id, error: "offline", wasRefusedByTheServer: false
            )
        }
        let afterTheOutage = try #require(await queue.fetchAll().first)
        #expect(afterTheOutage.attemptCount == 20)
        #expect(afterTheOutage.refusalCount == 0)

        // **Exactly one refusal, then nothing but outage.** A started engine
        // drains on its own, so how many refusals land is not something this
        // test gets to decide — and a first version enqueued sixty, watched
        // background drains push the count past the ceiling, and failed
        // intermittently on a row that had blocked for a perfectly good
        // reason. Following the one refusal with network errors keeps
        // `refusalCount` pinned at 1 while `attemptCount` climbs, which is the
        // relationship under test.
        transport.enqueueError(refusal())
        for _ in 0..<60 { transport.enqueueError(offline()) }
        transport.enqueueEvents([])
        await engine.start()
        await engine.replayMutationsForTesting()

        // Waits for EITHER outcome. A wait admitting only success turns a real
        // failure into a sixty-second timeout naming a condition rather than a
        // property, because the row blocks immediately under the defect and
        // the count being waited for never arrives.
        try await SyncEngineTestKit.awaitCondition(description: "the refusal settled") {
            let row = try await queue.fetchAll().first
            return row?.state == .blocked || (row?.refusalCount ?? 0) >= 1
        }

        let row = try #require(await queue.fetchAll().first)
        #expect(row.state != .blocked, "an outage must not spend the refusal budget")
        #expect(row.refusalCount == 1, "one refusal, however many attempts")
        #expect(row.attemptCount > 20, "and the displayed count kept counting")
        await engine.stop()
    }

    /// A second queue over the same container reads the same numbers, so both
    /// are in the row rather than in the actor that wrote them — the property
    /// the block-reason column has its own test for.
    @Test("both counters are in the store, not in the writer's memory")
    func bothCountersArePersisted() async throws {
        let (store, queue, container) = try await MarfaSDKTest.makeInMemoryStorePair()
        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        let item = try await store.createItem(input)
        try await queue.enqueueCreateItem(input, localId: item.id)
        let id = try #require(await queue.fetchAll().first?.id)

        try await queue.recordFailure(id: id, error: "offline", wasRefusedByTheServer: false)
        try await queue.recordFailure(id: id, error: "refused", wasRefusedByTheServer: true)

        let reopened = MutationQueue(modelContainer: container)
        let row = try #require(await reopened.fetchAll().first)
        #expect(row.attemptCount == 2)
        #expect(row.refusalCount == 1)
    }
}
