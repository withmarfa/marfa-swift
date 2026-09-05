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
        await engine.replayMutationsForTesting()
        try await SyncEngineTestKit.awaitCondition(description: "the write was attempted") {
            transport.calls.contains { $0.path == "/items" && $0.method == .post }
        }
        #expect(try await queue.fetchAll().count == 1, "a suspension must not discard the write")

        // The discriminator: an ordinary 403 still ends the mutation, so the
        // assertion above is about the code rather than about 403s having
        // stopped being permanent.
        transport.enqueueError(ordinaryForbidden())
        await engine.replayMutationsForTesting()
        try await SyncEngineTestKit.awaitCondition(description: "the queue drained") {
            try await queue.fetchAll().isEmpty
        }
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

        // The discriminator: an ordinary refusal at the same count does block,
        // so the assertion above is about the code rather than about the
        // ceiling having stopped working.
        #expect(PendingMutationBlockReason.classify(
            error: MarfaError(code: "teapot", message: "no", status: 418),
            kind: .createItem, attemptCount: ceiling, ceiling: ceiling
        ) == .retriesExhausted)
    }
}
