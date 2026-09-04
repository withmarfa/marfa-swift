import Foundation
import Testing
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// Every removal the server announces, and the one it does not announce at all.
///
/// A removal reaches a device two ways and the SDK handled neither. A row
/// purged while the device was away is absent from the server rather than
/// changed on it, so no event describes it and nothing later corrects it — the
/// re-import is the only pass that can notice, and it only ever upserted. A row
/// purged while the device is watching is announced as `item.purged`, which
/// fell through a `default` arm that broke in silence.
///
/// Both are the same sentence, so they are pinned in one place: the engine
/// applies every removal the server announces. Each test asserts on what the
/// store holds afterwards, because that is what an app renders.
@Suite("What the engine removes", .timeLimit(.minutes(1)))
struct SyncEngineRemovalTests {

    // MARK: - Fixtures

    private func item(
        _ id: String,
        body: String = "b",
        state: ItemState = .active,
        version: Int = 1
    ) -> Item {
        Item(
            createdAt: "2026-09-03T09:00:00Z",
            id: id,
            properties: ["body": .string(body)],
            schemaVersion: 1,
            source: "test",
            sourceId: nil,
            state: state,
            tier: .feed,
            timestamp: "2026-09-03T09:00:00Z",
            type: "core.note",
            updatedAt: "2026-09-03T09:00:00Z",
            version: version
        )
    }

    private func pair(_ item: Item) -> ItemWithMetadata {
        ItemWithMetadata(
            item: item,
            metadata: Metadata(extensions: [:], itemId: item.id, tags: [])
        )
    }

    private func noEdges() -> PaginatedResult<Edge> {
        PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false)
    }

    private func page(_ items: [Item]) -> PaginatedResult<ItemWithMetadata> {
        PaginatedResult<ItemWithMetadata>(
            data: items.map(pair), cursor: nil, hasMore: false
        )
    }

    private struct ItemFrame: Encodable {
        let type: String
        let item: Item
    }

    private func frame(_ type: String, _ item: Item, id: String = "evt-1") throws -> SSEEvent {
        let data = try JSONEncoder().encode(ItemFrame(type: type, item: item))
        return SSEEvent(id: id, event: type, data: String(decoding: data, as: UTF8.self))
    }

    private func storedIds(_ store: LocalStore) async throws -> Set<String> {
        // `nil` filters is every state, so a row that only went to the bin is
        // still counted here — this has to tell "gone" from "trashed" apart.
        Set(try await store.fetchItems(filters: nil).data.map(\.id))
    }

    // MARK: - The re-import

    @Test("a row the server no longer has is gone after a re-import")
    func reimportRemovesARowTheServerDropped() async throws {
        let (store, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await store.upsertItem(item("kept"))
        try await store.upsertItem(item("purged-while-away"))

        transport.enqueue(page([item("kept")]))
        transport.enqueue(noEdges())

        _ = try await engine.performInitialSync()

        #expect(try await storedIds(store) == ["kept"])
    }

    @Test("a row a queued create still owns survives the re-import")
    func reimportKeepsARowWithAQueuedCreate() async throws {
        let (store, queue, connManager) = try await makeHookedFixture()
        // The write lands while the import is paging, which is the only way it
        // can be here at all: `performInitialSync` refuses over a queue that
        // holds anything, and that check runs once, before the first page.
        // Someone writing a note while their library downloads lands in the
        // gap, and the row the server has never heard of is the one a prune
        // would take.
        let hooked = HookedTransport(onCall: { [store, queue] path in
            guard path == "/items" else { return }
            let created = try await store.createItem(
                CreateItemInput(type: "core.note", properties: ["body": .string("written mid-import")])
            )
            try await queue.enqueueCreateItem(
                CreateItemInput(type: "core.note", properties: ["body": .string("written mid-import")], id: created.id),
                localId: created.id
            )
        })
        let engine = SyncEngine(
            transport: hooked,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        try await store.upsertItem(item("kept"))

        await hooked.enqueue(page([item("kept")]))
        await hooked.enqueue(noEdges())

        _ = try await engine.performInitialSync()

        let ids = try await storedIds(store)
        #expect(ids.contains("kept"))
        // Two rows, not one: the mid-import create is still here.
        #expect(ids.count == 2)
    }

    @Test("a row the server sent as trashed is kept, not pruned")
    func reimportKeepsATrashedRowTheServerSent() async throws {
        let (store, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await store.upsertItem(item("binned", state: .trashed))

        transport.enqueue(page([item("binned", state: .trashed)]))
        transport.enqueue(noEdges())

        _ = try await engine.performInitialSync()

        #expect(try await storedIds(store) == ["binned"])
    }

    @Test("the re-import asks for every state, so the bin is not mistaken for a purge")
    func reimportAsksForEveryState() async throws {
        // The one wire assertion here, and it decides whether the prune is safe
        // at all. `GET /items` excludes trashed rows unless asked otherwise, so
        // an import that does not widen sees a bin full of rows as a server
        // that has purged all of them — and empties the device's bin on every
        // re-import. A mock answers whatever is queued regardless of the query,
        // so nothing downstream of here can catch the omission.
        let (_, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueue(page([]))
        transport.enqueue(noEdges())

        _ = try await engine.performInitialSync()

        let itemCalls = transport.calls.filter { $0.path == "/items" }
        #expect(itemCalls.count == 1)
        let query = itemCalls.first?.query ?? []
        #expect(query.contains { $0.0 == "state" && $0.1 == "any" })
    }

    // MARK: - The announcement

    @Test("an item.purged frame removes the row")
    func purgedFrameRemovesTheRow() async throws {
        let (store, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await store.upsertItem(item("doomed"))

        await engine._applyEventForTesting(try frame("item.purged", item("doomed")))

        #expect(try await storedIds(store).isEmpty)
    }

    @Test("an item.deleted frame trashes the row rather than removing it")
    func deletedFrameKeepsTheRow() async throws {
        // The control for the test above. A purge and a trash arrive as
        // different frames and must not converge on the same outcome: an
        // assertion that only proved "the row went away" would pass against an
        // engine that removed both.
        let (store, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await store.upsertItem(item("binned"))

        await engine._applyEventForTesting(
            try frame("item.deleted", item("binned", state: .trashed, version: 2))
        )

        #expect(try await storedIds(store) == ["binned"])
        #expect(try await store.fetchItem(id: "binned").state == .trashed)
    }

    @Test("an event type the engine has no case for is reported, not dropped in silence")
    func unknownEventTypeIsReported() async throws {
        // This is what let `item.purged` sit unhandled: a type the engine does
        // not know looked exactly like one it deliberately ignores, and nothing
        // anywhere could tell them apart.
        let (_, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()

        await engine._applyEventForTesting(
            SSEEvent(id: "evt-9", event: "item.something_new", data: "{}")
        )

        #expect(await engine.unhandledEventTypesForTesting == ["item.something_new"])
    }

    @Test("a type the engine does handle is not reported as unhandled")
    func handledEventTypeIsNotReported() async throws {
        // Control for the test above: a counter that reported every event would
        // pass it while saying nothing.
        let (store, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await store.upsertItem(item("known"))

        await engine._applyEventForTesting(
            try frame("item.updated", item("known", body: "edited", version: 2))
        )

        #expect(await engine.unhandledEventTypesForTesting.isEmpty)
    }

    // MARK: - What the app is told

    @Test("the purge frame announces a purge, which is not the news a trash carries")
    func purgedFrameAnnouncesItsOwnEvent() async throws {
        // An app holding the id outside the store learns the row is gone from
        // this event and from nothing else. `.itemDeleted` would tell it the
        // row went to a bin it can be restored from, and the store assertions
        // above cannot tell the two apart: both leave the same store.
        let (store, _, _, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await store.upsertItem(item("doomed"))

        // Subscribed before the apply, or the emission this is about would
        // have happened before anything was listening.
        let events = engine.events
        await engine._applyEventForTesting(try frame("item.purged", item("doomed")))

        let published = await SyncEngineTestKit.publishedEvents(from: events, closing: engine)
        guard case let .itemPurged(id) = published.first else {
            Issue.record("expected .itemPurged, got \(published)")
            return
        }
        #expect(id == "doomed")
    }

    @Test("the re-import announces the rows it removed")
    func reimportAnnouncesWhatItPruned() async throws {
        // The prune is the only pass that notices a row purged while the
        // device was away, so it is also the only thing that can tell an app
        // holding that id. Removing the row silently would leave a view
        // showing something the store no longer has.
        let (store, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        try await store.upsertItem(item("kept"))
        try await store.upsertItem(item("purged-while-away"))

        transport.enqueue(page([item("kept")]))
        transport.enqueue(noEdges())

        let events = engine.events
        _ = try await engine.performInitialSync()

        let published = await SyncEngineTestKit.publishedEvents(from: events, closing: engine)
        let purged = published.compactMap { event -> String? in
            if case let .itemPurged(id) = event { return id }
            return nil
        }
        #expect(purged == ["purged-while-away"])
    }

    @Test("a row a queued bulk create still owns survives the re-import")
    func reimportKeepsARowWithAQueuedBulkCreate() async throws {
        // The same protection as the queued-create case above, reached by the
        // other kind that carries one. A `bulk` sets no `localId` at all — its
        // ids are one per payload entry — so a protection reading only
        // `createItem` would leave these rows to be pruned, which is the
        // create case's data loss one branch over.
        let (store, queue, connManager) = try await makeHookedFixture()
        let hooked = HookedTransport(onCall: { [store, queue] path in
            guard path == "/items" else { return }
            let created = try await store.createItem(
                CreateItemInput(type: "core.note", properties: ["body": .string("bulk-written mid-import")])
            )
            try await queue.enqueueBulk(
                BulkInput(items: [BulkItemInput(id: created.id, type: "core.note")])
            )
        })
        let engine = SyncEngine(
            transport: hooked,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager
        )
        try await store.upsertItem(item("kept"))

        await hooked.enqueue(page([item("kept")]))
        await hooked.enqueue(noEdges())

        _ = try await engine.performInitialSync()

        let ids = try await storedIds(store)
        #expect(ids.contains("kept"))
        #expect(ids.count == 2)
    }

    // MARK: - Helpers

    private func makeHookedFixture() async throws -> (LocalStore, MutationQueue, ConnectionStateManager) {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        return (store, queue, ConnectionStateManager())
    }
}

/// A ``MockTransport`` that runs a closure when a request arrives, before it
/// answers.
///
/// The queued-create case cannot be set up in advance: the import refuses over
/// a queue that already holds work, so the only reachable version of it is a
/// write that lands while the pages are in flight. Nothing in `MockTransport`
/// offers a point inside that window.
actor HookedTransport: Transport {
    private let inner = MockTransport()
    private let onCall: @Sendable (String) async throws -> Void

    init(onCall: @escaping @Sendable (String) async throws -> Void) {
        self.onCall = onCall
    }

    func enqueue(_ response: some Encodable) {
        inner.enqueue(response)
    }

    var calls: [MockTransport.Call] {
        inner.calls
    }

    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T {
        try await onCall(path)
        return try await inner.request(method: method, path: path, body: body, query: query)
    }

    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> ConflictResult<T> {
        try await inner.requestWithConflict(method: method, path: path, body: body, query: query)
    }

    func rawRequest(
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?,
        query: [(String, String)]?
    ) async throws -> (Data, HTTPURLResponse) {
        try await inner.rawRequest(
            method: method, path: path, body: body, contentType: contentType, query: query
        )
    }

    func rawUpload(
        method: HTTPMethod,
        path: String,
        body: Data,
        contentType: String?,
        query: [(String, String)]?,
        onBytesSent: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        try await inner.rawUpload(
            method: method, path: path, body: body, contentType: contentType,
            query: query, onBytesSent: onBytesSent
        )
    }

    nonisolated func eventStream(
        path: String,
        query: [(String, String)]?,
        lastEventID: String?
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        inner.eventStream(path: path, query: query, lastEventID: lastEventID)
    }
}
