import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// A space suspended by the platform must not cost a device its queued work.
///
/// The server refuses every write from a suspended space with `403
/// space_suspended`. The kit treats a 403 as permanent, so each queued write
/// was dead-lettered on the first drain after the suspension — and a
/// suspension is a statement about the *environment* that clears with nothing
/// the app or the person can do. The space comes back and the work does not.
@Suite("A suspended space does not discard the queue", .timeLimit(.minutes(1)))
struct SuspendedSpaceTests {

    private func suspended() -> MarfaError {
        parseMarfaError(
            data: Data(#"{"error":{"code":"space_suspended","message":"Space is suspended"}}"#.utf8),
            statusCode: 403
        )
    }

    private func ordinaryForbidden() -> MarfaError {
        parseMarfaError(
            data: Data(#"{"error":{"code":"forbidden","message":"Not allowed"}}"#.utf8),
            statusCode: 403
        )
    }

    /// A 403 discards the server's `code` at parse time, so nothing
    /// downstream can tell a suspension from any other refusal. A 400 and a
    /// 409 both keep theirs, each with a comment saying why.
    @Test("a 403 keeps the code the server sent")
    func forbiddenKeepsItsCode() {
        #expect(suspended().code == "space_suspended")
        #expect(ordinaryForbidden().code == "forbidden")
    }

    @Test("a suspension is not permanent, and an ordinary refusal still is")
    func suspensionIsNotPermanent() {
        #expect(suspended().isPermanent == false)
        #expect(ordinaryForbidden().isPermanent == true)
    }

    /// The consequence that matters. A permanent failure is dead-lettered on
    /// the first attempt; a suspension has to stay queued for the space to
    /// come back to.
    @Test("a queued write survives a suspension and is dropped by a real refusal")
    func theQueueSurvivesASuspension() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueueEvents([])
        await engine.start()

        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        let item = try await store.createItem(input)
        try await queue.enqueueCreateItem(input, localId: item.id)

        transport.enqueueError(suspended())
        // **Waited for rather than asserted straight after the call**, and a
        // draft that asserted directly passed under `--filter` and failed
        // under the full parallel suite. A started engine drains on its own
        // whenever the queue signals, and `replayMutations` collapses
        // concurrent entries with an overlap guard — so the explicit call
        // here is sometimes swallowed by a proactive drain already running,
        // and the attempt arrives from that one instead. The property holds
        // either way; the timing does not.
        await engine.replayMutationsForTesting()
        try await SyncEngineTestKit.awaitCondition(description: "the write was attempted") {
            transport.calls.contains { $0.path == "/items" && $0.method == .post }
        }

        // **Present is not enough — the row has to still be replayable.** A
        // classifier that blocked a suspension instead of exempting it leaves
        // the row in the queue too, so a count alone passes for the outcome
        // this test exists to rule out.
        let survived = try await queue.fetchAll()
        #expect(survived.count == 1, "a suspension must not discard the write")
        // **Not blocked** is the claim, and asserting `.pending` was narrower
        // than that: a started engine may have re-marked the row `.inFlight`
        // for its next attempt by the time this reads it, which satisfies the
        // property and failed the assertion. Both states mean the same thing
        // here — the row is still the engine's to send.
        #expect(survived.first?.state != .blocked)
        #expect(survived.first?.blockedReason == nil)

        // The discriminator: an ordinary 403 still ends the mutation, so the
        // assertion above is about the code rather than about 403s having
        // stopped being permanent.
        transport.enqueueError(ordinaryForbidden())
        await engine.replayMutationsForTesting()
        try await SyncEngineTestKit.awaitCondition(description: "the queue drained") {
            try await queue.fetchAll().isEmpty
        }
        // And it left by the dead-letter path rather than by any removal,
        // which `isEmpty` on its own does not say.
        #expect(try await queue.fetchDropped().count == 1)
        await engine.stop()
    }

    /// A suspension outlasting the retry ceiling must still not block.
    ///
    /// Blocking would be better than dropping and is still wrong: a blocked
    /// row waits for somebody to press something, and nobody pressed anything
    /// to cause a suspension. It belongs to the class the classifier already
    /// exempts — a `5xx`, a `429`, a `401` — which never blocks however often
    /// it fails.
    @Test("a long suspension does not block the row either")
    func aLongSuspensionDoesNotBlock() {
        let ceiling = 5
        // One past the ceiling, which is what blocks anything else.
        #expect(PendingMutationBlockReason.classify(
            error: suspended(), kind: .createItem, attemptCount: ceiling, ceiling: ceiling
        ) == nil)

        // **The discriminator is an ordinary 403**, and a first draft used a
        // 418 — which rules out "the ceiling stopped working" and says
        // nothing about the failure that matters. Widening the classifier to
        // exempt every 403 left the whole package green against the 418, so
        // the comment claiming this guarded the code was false.
        #expect(PendingMutationBlockReason.classify(
            error: ordinaryForbidden(),
            kind: .createItem, attemptCount: ceiling, ceiling: ceiling
        ) == .retriesExhausted)
    }

    /// What the change is actually for, end to end, and the only test that
    /// states it: a suspension outlasting the ceiling, then the space coming
    /// back, and the write arriving.
    ///
    /// Everything above pins a property in isolation. None of it shows the
    /// row still being *attempted* after the ceiling, which is the difference
    /// between a write that waits and one that is quietly stuck.
    @Test("a write survives a long suspension and lands when the space returns")
    func theWriteLandsWhenTheSpaceReturns() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueueEvents([])
        await engine.start()

        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        let item = try await store.createItem(input)
        try await queue.enqueueCreateItem(input, localId: item.id)

        // Well past the retry ceiling of five. The count asserted below is a
        // floor rather than an equality: a started engine drains on its own
        // too, so how many attempts happen is not something this test gets to
        // decide — only that they kept happening past the ceiling.
        for _ in 0..<8 {
            transport.enqueueError(suspended())
            await engine.replayMutationsForTesting()
        }
        try await SyncEngineTestKit.awaitCondition(description: "attempts past the ceiling") {
            transport.calls.filter { $0.path == "/items" && $0.method == .post }.count > 5
        }
        let waiting = try await queue.fetchAll()
        #expect(waiting.count == 1)
        #expect(waiting.first?.state != .blocked, "still replayable, not blocked")

        // The space comes back.
        let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        transport.enqueue(ItemResponse(
            item: Item(
                createdAt: now, id: item.id, properties: ["body": .string("x")],
                schemaVersion: 1, source: "test", state: .active, tier: .library,
                timestamp: now, type: "core.note", updatedAt: now, version: 1
            ),
            metadata: nil
        ))
        await engine.replayMutationsForTesting()
        try await SyncEngineTestKit.awaitCondition(description: "the write landed") {
            try await queue.fetchAll().isEmpty
        }
        #expect(try await queue.fetchDropped().isEmpty, "nothing was dead-lettered on the way")
        await engine.stop()
    }
}
