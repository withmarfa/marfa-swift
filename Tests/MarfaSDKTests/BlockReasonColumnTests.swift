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

    /// **Every case, read off the row rather than through `toRecord()`.**
    /// The accessor's fallback resolves an unreadable value to
    /// `retriesExhausted`, so a build that stored garbage for exactly that
    /// case would be indistinguishable from one that stored it correctly —
    /// and every existing assertion went through that accessor. Reading the
    /// column is the only way the write itself is under test.
    @Test("every reason round-trips through the column as itself",
          arguments: PendingMutationBlockReason.allCases)
    func everyReasonRoundTrips(_ reason: PendingMutationBlockReason) async throws {
        let (queue, container, id) = try await enqueued()
        try await queue.recordBlocked(id: id, reason: reason, error: "why")

        let context = ModelContext(container)
        let model = try #require(
            context.fetch(FetchDescriptor<PendingMutationModel>()).first { $0.id == id }
        )
        #expect(model.blockedReason == reason.rawValue)
        #expect(model.lastError == "why")
    }

    /// The gate `toRecord()` applies, which nothing pinned: change it and
    /// every `.pending` row starts reporting a reason through a public field.
    ///
    /// It is reachable rather than theoretical. The engine re-admits a
    /// `resolverMissing` row the moment a resolver registers, without clearing
    /// the block, so a transient failure after that leaves a `.pending` row
    /// carrying a reason — invisible only because of this gate.
    @Test("a row that is not blocked reports no reason, whatever the column holds")
    func anUnblockedRowReportsNoReason() async throws {
        let (queue, container, id) = try await enqueued()
        let context = ModelContext(container)
        let model = try #require(
            context.fetch(FetchDescriptor<PendingMutationModel>()).first { $0.id == id }
        )
        model.blockedReason = PendingMutationBlockReason.resolverMissing.rawValue
        model.state = .pending
        try context.save()

        let record = try #require(await queue.fetchAll().first { $0.id == id })
        #expect(record.blockedReason == nil)
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

    // MARK: - The rows a shipped build already wrote

    /// `v16.0.0` ships schema V2 and wrote the reason as a
    /// `[blocked:<reason>] message` prefix inside `lastError`. Those rows are
    /// on devices now, and the V2 to V3 migration adds the column as NULL — so
    /// reading the column alone loses the reason on upgrade.
    ///
    /// **It loses it in the worst direction.** A `resolverMissing` row read as
    /// `retriesExhausted` stops auto-replaying when a resolver is registered,
    /// which is the recovery `16.0.0` advertised, and the raw prefix starts
    /// appearing in front of the error text an app shows a person.
    @Test("a row written before the column reports its reason and a clean message")
    func aLegacyRowIsStillReadable() async throws {
        let (queue, container, id) = try await enqueued()

        // Exactly what `16.0.0` left behind: the prefix in the message, no
        // column.
        let context = ModelContext(container)
        let model = try #require(
            context.fetch(FetchDescriptor<PendingMutationModel>()).first { $0.id == id }
        )
        model.lastError = "[blocked:resolverMissing] no conflict resolver registered"
        model.blockedReason = nil
        model.state = .blocked
        try context.save()

        let record = try #require(await queue.fetchAll().first { $0.id == id })
        #expect(record.blockedReason == .resolverMissing)
        #expect(record.lastError == "no conflict resolver registered")
    }

    /// Retrying such a row scrubs the prefix, because nothing else ever
    /// rewrites that column — left alone it would sit in front of the error
    /// text for ever.
    @Test("retrying a legacy row scrubs the prefix from its message")
    func retryingALegacyRowScrubsThePrefix() async throws {
        let (queue, container, id) = try await enqueued()
        let context = ModelContext(container)
        let model = try #require(
            context.fetch(FetchDescriptor<PendingMutationModel>()).first { $0.id == id }
        )
        model.lastError = "[blocked:conflictUnresolved] the server refused it"
        model.state = .blocked
        try context.save()

        try await queue.clearBlock(id: id)

        let record = try #require(await queue.fetchAll().first { $0.id == id })
        #expect(record.lastError == "the server refused it")
    }

    /// The distinction the fallback turns on, and the reason `nil` and
    /// unrecognized cannot share a branch: an unreadable token means a newer
    /// build wrote something this one cannot name, while a missing column on a
    /// blocked row means a legacy row whose answer is in the message.
    @Test("a blocked row with neither a column nor a prefix reads as retries exhausted")
    func aBlockedRowWithNoReasonAnywhereFallsBack() async throws {
        let (queue, container, id) = try await enqueued()
        let context = ModelContext(container)
        let model = try #require(
            context.fetch(FetchDescriptor<PendingMutationModel>()).first { $0.id == id }
        )
        model.lastError = "something went wrong"
        model.blockedReason = nil
        model.state = .blocked
        try context.save()

        let record = try #require(await queue.fetchAll().first { $0.id == id })
        #expect(record.blockedReason == .retriesExhausted)
        #expect(record.lastError == "something went wrong")
    }
}
