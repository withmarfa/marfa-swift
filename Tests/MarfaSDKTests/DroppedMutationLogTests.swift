import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport
import SwiftData

/// Tests for the dropped-mutation log added in 5.2.0:
/// `MutationQueue.recordDropped(record:droppedAt:error:)`,
/// `fetchDropped()`, `dismissDropped(id:)`,
/// `dismissDroppedOlderThan(_:)`, `dismissAllDropped()`, and the
/// cascade-persists-orphans behavior of
/// `dropMutationsReferencingLocalId(_:droppedAt:error:)`.
@Suite("DroppedMutationLog")
struct DroppedMutationLogTests {

    // MARK: - Helpers

    /// Builds a queue with one or more enqueued live rows, returning
    /// the live records so callers can pass them to `recordDropped`.
    private func makeQueueWithEnqueuedDelete(id: String) async throws -> (
        MutationQueue,
        PendingMutationRecord
    ) {
        let (_, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await queue.enqueueDeleteItem(id: id)
        let records = try await queue.fetchAll()
        return (queue, records[0])
    }

    // MARK: - recordDropped

    @Test("recordDropped inserts a dropped row and removes the live row atomically")
    func recordDroppedAtomic() async throws {
        let (queue, record) = try await makeQueueWithEnqueuedDelete(id: "server-1")
        let error = ValidationError(message: "bad delete", details: ["why": .string("nope")])
        let droppedAt = Date()

        try await queue.recordDropped(record: record, droppedAt: droppedAt, error: error)

        // Live queue empty, dropped log has one row matching shape.
        #expect(try await queue.isEmpty)
        let log = try await queue.fetchDropped()
        #expect(log.count == 1)
        let entry = try #require(log.first)
        #expect(entry.id == record.id)
        #expect(entry.kind == .deleteItem)
        #expect(entry.localId == "server-1")
        #expect(entry.errorStatus == 400)
        #expect(entry.errorCode == "validation_error")
        #expect(entry.errorMessage == "bad delete")
        #expect(entry.errorDetailsJson != nil)
        #expect(entry.attemptCount == record.attemptCount + 1)
        #expect(!entry.enqueuedAt.isEmpty)
        #expect(!entry.droppedAt.isEmpty)
    }

    @Test("recordDropped tolerates a missing live row (cascade-already-removed case)")
    func recordDroppedTolerantOfMissingLive() async throws {
        let (queue, record) = try await makeQueueWithEnqueuedDelete(id: "server-2")
        // Remove the live row first — simulating the cascade path
        // having already pruned it.
        try await queue.remove(id: record.id)
        #expect(try await queue.isEmpty)

        // Should not throw.
        let error = NotFoundError(message: "gone")
        try await queue.recordDropped(record: record, droppedAt: Date(), error: error)

        let log = try await queue.fetchDropped()
        #expect(log.count == 1)
    }

    @Test("recordDropped caps errorMessage at 1024 characters")
    func recordDroppedCapsErrorMessage() async throws {
        let (queue, record) = try await makeQueueWithEnqueuedDelete(id: "server-3")
        let huge = String(repeating: "x", count: 4096)
        let error = ValidationError(message: huge)

        try await queue.recordDropped(record: record, droppedAt: Date(), error: error)

        let log = try await queue.fetchDropped()
        let entry = try #require(log.first)
        #expect(entry.errorMessage.count == 1024)
    }

    // MARK: - fetchDropped ordering

    @Test("fetchDropped returns rows newest first")
    func fetchDroppedNewestFirst() async throws {
        let (_, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()

        // Three live rows we'll mark dropped at three distinct times.
        try await queue.enqueueDeleteItem(id: "server-A")
        try await queue.enqueueDeleteItem(id: "server-B")
        try await queue.enqueueDeleteItem(id: "server-C")
        let live = try await queue.fetchAll()

        let now = Date()
        let twoHoursAgo = now.addingTimeInterval(-7200)
        let oneHourAgo = now.addingTimeInterval(-3600)
        let recent = now

        try await queue.recordDropped(
            record: live[0], droppedAt: twoHoursAgo,
            error: ValidationError(message: "oldest")
        )
        try await queue.recordDropped(
            record: live[1], droppedAt: oneHourAgo,
            error: ValidationError(message: "middle")
        )
        try await queue.recordDropped(
            record: live[2], droppedAt: recent,
            error: ValidationError(message: "newest")
        )

        let log = try await queue.fetchDropped()
        #expect(log.count == 3)
        #expect(log[0].errorMessage == "newest")
        #expect(log[1].errorMessage == "middle")
        #expect(log[2].errorMessage == "oldest")
    }

    // MARK: - Dismissal API

    @Test("dismissDropped removes a single row")
    func dismissDroppedOne() async throws {
        let (_, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await queue.enqueueDeleteItem(id: "server-A")
        try await queue.enqueueDeleteItem(id: "server-B")
        let live = try await queue.fetchAll()
        for record in live {
            try await queue.recordDropped(
                record: record, droppedAt: Date(),
                error: ValidationError(message: "x")
            )
        }
        #expect(try await queue.fetchDropped().count == 2)

        try await queue.dismissDropped(id: live[0].id)
        let remaining = try await queue.fetchDropped()
        #expect(remaining.count == 1)
        #expect(remaining[0].id == live[1].id)
    }

    @Test("dismissDropped is a no-op for unknown ids")
    func dismissDroppedUnknownId() async throws {
        let (_, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await queue.dismissDropped(id: "does-not-exist")
        #expect(try await queue.fetchDropped().isEmpty)
    }

    @Test("dismissDroppedOlderThan removes only rows strictly older than cutoff")
    func dismissDroppedOlderThanStrict() async throws {
        let (_, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await queue.enqueueDeleteItem(id: "old")
        try await queue.enqueueDeleteItem(id: "mid")
        try await queue.enqueueDeleteItem(id: "new")
        let live = try await queue.fetchAll()

        let now = Date()
        let twoHoursAgo = now.addingTimeInterval(-7200)
        let oneHourAgo = now.addingTimeInterval(-3600)
        let recent = now

        try await queue.recordDropped(
            record: live[0], droppedAt: twoHoursAgo,
            error: ValidationError(message: "oldest")
        )
        try await queue.recordDropped(
            record: live[1], droppedAt: oneHourAgo,
            error: ValidationError(message: "middle")
        )
        try await queue.recordDropped(
            record: live[2], droppedAt: recent,
            error: ValidationError(message: "newest")
        )

        // Cutoff strictly between oldest and middle — only the
        // 2-hour-old row qualifies.
        let cutoff = now.addingTimeInterval(-5400) // 90 minutes ago
        try await queue.dismissDroppedOlderThan(cutoff)

        let remaining = try await queue.fetchDropped()
        #expect(remaining.count == 2)
        let kept = remaining.map(\.errorMessage).sorted()
        #expect(kept == ["middle", "newest"])
    }

    @Test("dismissDroppedOlderThan preserves rows whose droppedAt exactly matches the cutoff")
    func dismissDroppedOlderThanCutoffBoundary() async throws {
        let (_, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await queue.enqueueDeleteItem(id: "boundary")
        let live = try await queue.fetchAll()

        let exactly = Date()
        try await queue.recordDropped(
            record: live[0], droppedAt: exactly,
            error: ValidationError(message: "boundary")
        )

        // Strictly less-than: a row dropped *at* the cutoff is kept.
        try await queue.dismissDroppedOlderThan(exactly)
        #expect(try await queue.fetchDropped().count == 1)
    }

    @Test("dismissAllDropped clears the entire log")
    func dismissAllClearsAll() async throws {
        let (_, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await queue.enqueueDeleteItem(id: "a")
        try await queue.enqueueDeleteItem(id: "b")
        try await queue.enqueueDeleteItem(id: "c")
        let live = try await queue.fetchAll()
        for record in live {
            try await queue.recordDropped(
                record: record, droppedAt: Date(),
                error: ValidationError(message: "x")
            )
        }
        #expect(try await queue.fetchDropped().count == 3)

        try await queue.dismissAllDropped()
        #expect(try await queue.fetchDropped().isEmpty)
    }

    // MARK: - Cascade persistence

    @Test("dropMutationsReferencingLocalId persists every cascaded orphan")
    func cascadePersistsOrphans() async throws {
        let (_, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()

        // Build the same shape the engine seeds in the cascade
        // integration test: createItem(A), updateItem(A), createEdge
        // (A → X), unrelated updateItem(Y) which must survive.
        let createInput = CreateItemInput(
            type: "core.note", properties: ["body": .string("")], id: "A"
        )
        try await queue.enqueueCreateItem(createInput, localId: "A")
        try await queue.enqueueUpdateItem(id: "A", properties: ["body": .string("typed")])
        try await queue.enqueueCreateEdge(
            source: "A", target: "X", edgeType: "in-thread",
            properties: nil, localEdgeId: "E-AX"
        )
        try await queue.enqueueUpdateItem(id: "Y", properties: ["body": .string("untouched")])

        // Engine would call recordDropped for A first; we mimic that.
        let live = try await queue.fetchAll()
        let rootRecord = try #require(live.first { $0.localId == "A" && $0.kind == .createItem })
        let droppedAt = Date()
        let error = ValidationError(message: "bad create")

        try await queue.recordDropped(
            record: rootRecord, droppedAt: droppedAt, error: error
        )
        let cascaded = try await queue.dropMutationsReferencingLocalId(
            "A", droppedAt: droppedAt, error: error
        )

        // The cascade returned the orphans.
        #expect(cascaded.count == 2)
        let cascadedKinds = Set(cascaded.map(\.kind))
        #expect(cascadedKinds == Set([.updateItem, .createEdge]))

        // Persisted log carries 3 rows: root + 2 orphans. Y's
        // updateItem stays in the live queue.
        let log = try await queue.fetchDropped()
        #expect(log.count == 3)
        let logKinds = Set(log.map(\.kind))
        #expect(logKinds == Set([.createItem, .updateItem, .createEdge]))

        // Y survives in the live queue.
        let surviving = try await queue.fetchAll()
        #expect(surviving.count == 1)
        #expect(surviving[0].localId == "Y")
    }
}
