import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// A ``LocalStoreWriting`` whose item writes fail on command.
///
/// Real SwiftData accepts every write the engine can construct, so the only
/// way to state what the engine does with an event the device cannot store is
/// to hand it a store that refuses one. The other writes are no-ops: these
/// tests are about the engine's cursor accounting, not about stored rows.
actor FailingLocalStore: LocalStoreWriting {

    private var failItemUpserts: Bool

    /// Items the store accepted, in order.
    private(set) var appliedItemIds: [String] = []

    /// Items the store refused, in order.
    private(set) var refusedItemIds: [String] = []

    init(failItemUpserts: Bool) {
        self.failItemUpserts = failItemUpserts
    }

    func setFailItemUpserts(_ shouldFail: Bool) {
        failItemUpserts = shouldFail
    }

    func upsertItem(_ item: Item) throws {
        guard failItemUpserts else {
            appliedItemIds.append(item.id)
            return
        }
        refusedItemIds.append(item.id)
        throw LocalStoreError.encodingFailure("upsertItem(\(item.id))")
    }

    /// Routed through ``upsertItem(_:)`` so the refusal stays keyed on the
    /// item write rather than on which of the two spellings the engine
    /// happens to use for an inbound frame.
    @discardableResult
    func applyServerItem(_ item: Item, rebasing edits: [PendingItemEdit]) throws -> Bool {
        try upsertItem(item)
        return true
    }

    @discardableResult
    func pruneItems(keeping: Set<String>, protecting: Set<String>) throws -> [String] { [] }

    func upsertEdge(_ edge: Edge) throws {}

    func deleteEdge(id: String) throws {}

    func upsertMetadata(_ metadata: Metadata) throws {}

    func purgeItem(id: String) throws {}
}

/// The `Last-Event-ID` cursor is the only durable record of how far the local
/// store has been brought forward. A reconnect resumes after it, so an event
/// the cursor has passed is never sent again — which makes advancing it past
/// an event that did not land the same thing as discarding that event.
@Suite("SyncEngine cursor durability", .timeLimit(.minutes(1)))
struct SyncEngineCursorDurabilityTests {

    private static let cursorKey = "last_event_id"

    private static func makeEngine(
        store: FailingLocalStore
    ) async throws -> (MutationQueue, MockTransport, ConnectionStateManager, SyncEngine) {
        let (_, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        // A device that has been running, not a cold start: without the
        // stamp the engine imports when it comes online and this suite's
        // response queue answers a call it never meant to make.
        try await SyncEngineTestKit.markImported(queue)
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        return (queue, transport, connManager, engine)
    }

    private static func itemCreatedEvent(id: String, itemId: String) throws -> SSEEvent {
        let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        let item = Item(
            createdAt: now, id: itemId,
            properties: ["body": .string("payload")],
            schemaVersion: 1, source: "test", state: .active, tier: .feed,
            timestamp: now, type: "core.note", updatedAt: now, version: 1
        )
        struct ItemPayload: Encodable { let item: Item }
        let data = try JSONEncoder().encode(ItemPayload(item: item))
        return SSEEvent(
            id: id,
            event: "item.created",
            data: String(decoding: data, as: UTF8.self)
        )
    }

    @Test("an event the store refuses does not move the cursor")
    func refusedEventLeavesCursorBehind() async throws {
        let store = FailingLocalStore(failItemUpserts: true)
        let (queue, _, _, engine) = try await Self.makeEngine(store: store)
        try await queue.saveSyncState(key: Self.cursorKey, value: "evt-0")

        await engine._applyEventForTesting(
            try Self.itemCreatedEvent(id: "evt-1", itemId: "server-1")
        )

        #expect(await store.refusedItemIds == ["server-1"])
        #expect(await store.appliedItemIds.isEmpty)
        #expect(try await queue.loadSyncState(key: Self.cursorKey) == "evt-0")
    }

    @Test("an event the store accepts moves the cursor")
    func acceptedEventAdvancesCursor() async throws {
        let store = FailingLocalStore(failItemUpserts: false)
        let (queue, _, _, engine) = try await Self.makeEngine(store: store)
        try await queue.saveSyncState(key: Self.cursorKey, value: "evt-0")

        await engine._applyEventForTesting(
            try Self.itemCreatedEvent(id: "evt-1", itemId: "server-1")
        )

        #expect(await store.appliedItemIds == ["server-1"])
        #expect(try await queue.loadSyncState(key: Self.cursorKey) == "evt-1")
    }

    @Test("a refused event stops the stream so later events cannot pass it")
    func refusedEventHaltsTheStream() async throws {
        let store = FailingLocalStore(failItemUpserts: true)
        let (queue, transport, connManager, engine) = try await Self.makeEngine(store: store)
        try await queue.saveSyncState(key: Self.cursorKey, value: "evt-0")

        // Two ordered events. Holding the cursor at the first one is only
        // worth anything if the second cannot carry it forward — a cursor
        // parked on `evt-2` skips `evt-1` on the next connection just as
        // surely as one that advanced on the failure itself.
        transport.enqueueEvents([
            try Self.itemCreatedEvent(id: "evt-1", itemId: "server-1"),
            try Self.itemCreatedEvent(id: "evt-2", itemId: "server-2"),
        ])

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.waitUntil(timeout: .seconds(2), description: "!store.refusedItemIds.isEmpty") {
            await !store.refusedItemIds.isEmpty
        }
        try await SyncEngineTestKit.expectRemainsFalse(for: .milliseconds(300)) {
            let cursor = try await queue.loadSyncState(key: Self.cursorKey)
            let applied = await store.appliedItemIds
            let refused = await store.refusedItemIds
            return cursor != "evt-0" || !applied.isEmpty || refused != ["server-1"]
        }

        await engine.stop()
    }
}
