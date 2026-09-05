import Testing
import Foundation
import SwiftData
@testable import MarfaSDK
import MarfaSDKTestSupport

/// A blocked row says why in its own column.
///
/// The reason used to ride inside `lastError` as a `[blocked:<reason>]` string
/// prefix, written in one place and parsed in another. These pin the two
/// properties that survived the move and the one that did not.
@Suite("A blocked row says why in its own column", .timeLimit(.minutes(1)))
struct BlockReasonColumnTests {

    private func enqueued() async throws -> (MutationQueue, ModelContainer, String) {
        let (store, queue, container) = try await MarfaSDKTest.makeInMemoryStorePair()
        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        let item = try await store.createItem(input)
        try await queue.enqueueCreateItem(input, localId: item.id)
        let id = try #require(await queue.fetchAll().first?.id)
        return (queue, container, id)
    }

    @Test("the reason is in the store, not in the writer's memory")
    func reasonIsPersisted() async throws {
        let (queue, container, id) = try await enqueued()
        try await queue.recordBlocked(id: id, reason: .resolverMissing, error: "no resolver")

        // A second queue over the same container reads it back. That is not a
        // reopen — the container is in-memory — but it is the property that
        // matters: the answer is in the row rather than in the actor that
        // wrote it, so nothing in memory carries it across.
        let reopened = MutationQueue(modelContainer: container)
        let record = try #require(await reopened.fetchAll().first { $0.id == id })
        #expect(record.blockedReason == .resolverMissing)
        #expect(record.lastError == "no resolver")
    }

    /// The message no longer carries a prefix a consumer has to strip, which
    /// is the whole reason the smuggling was worth removing.
    @Test("the message is the message, with nothing stamped on the front")
    func messageIsNotDecorated() async throws {
        let (queue, _, id) = try await enqueued()
        try await queue.recordBlocked(id: id, reason: .conflictUnresolved, error: "409 from the server")

        let record = try #require(await queue.fetchAll().first { $0.id == id })
        #expect(record.lastError == "409 from the server")
        #expect(record.lastError?.contains("[blocked:") == false)
    }

    /// The one property the string form had that had to be kept. A build
    /// meeting a reason a newer build wrote resolves it toward the reason that
    /// promises no automatic recovery — the alternative is an old build
    /// replaying a row forever over a reason it cannot read.
    @Test("a reason this build does not recognize reads as retries exhausted")
    func unknownReasonFallsBack() async throws {
        let (queue, container, id) = try await enqueued()
        try await queue.recordBlocked(id: id, reason: .conflictUnresolved, error: "x")

        // Written directly, as a future build would have.
        let context = ModelContext(container)
        let model = try #require(
            context.fetch(FetchDescriptor<PendingMutationModel>()).first { $0.id == id }
        )
        model.blockedReason = "a_reason_from_the_future"
        try context.save()

        let record = try #require(await queue.fetchAll().first { $0.id == id })
        #expect(record.blockedReason == .retriesExhausted)
    }

    /// Clearing a block clears the reason column, not only the state.
    ///
    /// **Asserted against the row rather than through `fetchAll()`, and the
    /// first version of this test was wrong for exactly that reason.**
    /// `toRecord()` reports a reason only while `state == .blocked`, so a
    /// record read after a retry says `nil` whatever the column holds — the
    /// assertion passed with the clear deleted. Nothing observable breaks if
    /// the column goes stale, which is why it is worth clearing anyway and
    /// why the test has to reach past the accessor that hides it: a column
    /// saying something false is a trap for whoever reads it next.
    @Test("retrying a blocked row clears its reason column")
    func clearingABlockClearsTheReason() async throws {
        let (queue, container, id) = try await enqueued()
        try await queue.recordBlocked(id: id, reason: .resolverMissing, error: "no resolver")
        try await queue.clearBlock(id: id)

        let context = ModelContext(container)
        let model = try #require(
            context.fetch(FetchDescriptor<PendingMutationModel>()).first { $0.id == id }
        )
        #expect(model.blockedReason == nil)
        #expect(model.state == .pending)
    }
}
