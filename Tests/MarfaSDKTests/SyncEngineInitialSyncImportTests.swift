import Foundation
import Testing
@testable import MarfaSDK
import MarfaSDKTestSupport

/// What the initial sync actually puts in the store.
///
/// The existing coverage drives `performInitialSync` with a single empty page
/// and asserts on the timestamp it stamps afterwards, which says nothing about
/// the import itself: not what lands, not that it pages, and — until this
/// suite — not that edges arrive at all. A device that signed in received every
/// item and none of its relationships, and nothing here failed.
@Suite("What the initial sync imports")
struct SyncEngineInitialSyncImportTests {

    // MARK: - Fixtures

    private func item(_ id: String, body: String = "b") -> Item {
        Item(
            createdAt: "2026-08-26T09:00:00Z",
            id: id,
            properties: ["body": .string(body)],
            schemaVersion: 1,
            source: "test",
            state: .active,
            tier: .feed,
            timestamp: "2026-08-26T09:00:00Z",
            type: "core.note",
            updatedAt: "2026-08-26T09:00:00Z",
            version: 1
        )
    }

    private func pair(
        _ id: String,
        tags: [String] = [],
        extensions: [String: [String: JSONValue]] = [:]
    ) -> ItemWithMetadata {
        ItemWithMetadata(
            item: item(id),
            metadata: Metadata(
                extensions: extensions.mapValues { JSONValue.dictionary($0) },
                itemId: id,
                tags: tags
            )
        )
    }

    private func edge(_ id: String, from source: String, to target: String,
                      type: String = "core.about") -> Edge {
        Edge(
            createdAt: "2026-08-26T09:00:00Z",
            edgeType: type,
            id: id,
            properties: [:],
            sourceId: source,
            targetId: target,
            updatedAt: "2026-08-26T09:00:00Z",
            version: 1
        )
    }

    private func noEdges() -> PaginatedResult<Edge> {
        PaginatedResult<Edge>(data: [], cursor: nil, hasMore: false)
    }

    private func noItems() -> PaginatedResult<ItemWithMetadata> {
        PaginatedResult<ItemWithMetadata>(data: [], cursor: nil, hasMore: false)
    }

    // MARK: - Items

    @Test("the items it fetched are in the store afterwards")
    func importsItemsIntoTheStore() async throws {
        let (store, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueue(
            PaginatedResult<ItemWithMetadata>(
                data: [pair("i1", tags: ["reading"]), pair("i2")],
                cursor: nil,
                hasMore: false
            )
        )
        transport.enqueue(noEdges())

        let imported = try await engine.performInitialSync()

        #expect(imported == 2)
        let stored = try await store.fetchItems(filters: nil)
        #expect(Set(stored.data.map(\.id)) == ["i1", "i2"])
        // Metadata rides along on the same pass; a tag that did not survive it
        // is indistinguishable to a reader from a tag nobody set.
        let meta = try await store.fetchMetadata(itemId: "i1")
        #expect(meta.tags == ["reading"])
    }

    @Test("the extensions the wire carried are in the store afterwards")
    func importsExtensionsIntoTheStore() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        let extensions = ExtensionsNamespace(
            transport: transport, localStore: store, mutationQueue: queue
        )
        transport.enqueue(
            PaginatedResult<ItemWithMetadata>(
                data: [pair("i1", tags: ["reading"], extensions: ["app": ["state": .string("held by the server")]])],
                cursor: nil,
                hasMore: false
            )
        )
        transport.enqueue(noEdges())

        _ = try await engine.performInitialSync()

        // Tags and extensions are two halves of one row on the wire, and the
        // import used to take only the first: an app reading sidecar state the
        // server already held saw nothing, with no second pass that would ever
        // fill it in.
        let namespace = try await extensions.get(itemId: "i1", namespace: "app")
        #expect(namespace?["state"] == .string("held by the server"))
    }

    @Test("a namespace the imported row leaves out is gone afterwards")
    func importRemovesANamespaceTheServerNoLongerHolds() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        let extensions = ExtensionsNamespace(
            transport: transport, localStore: store, mutationQueue: queue
        )
        try await store.upsertItem(item("i1"))
        _ = try await store.setExtension(itemId: "i1", namespace: "stale", data: ["k": .string("v")])
        transport.enqueue(
            PaginatedResult<ItemWithMetadata>(
                data: [pair("i1", extensions: ["current": ["k": .string("v")]])],
                cursor: nil,
                hasMore: false
            )
        )
        transport.enqueue(noEdges())

        _ = try await engine.performInitialSync()

        // Landing the namespaces the row carries is not the whole contract:
        // a write that set each of them in turn would pass the test above and
        // still leave a namespace the server has dropped alive here, where a
        // re-import is the one thing that would otherwise clear it.
        #expect(try await extensions.get(itemId: "i1", namespace: "stale") == nil)
        #expect(try await extensions.get(itemId: "i1", namespace: "current") != nil)
    }

    @Test("it keeps paging until the server says there is no more")
    func importsPastTheFirstPage() async throws {
        let (store, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueue(
            PaginatedResult<ItemWithMetadata>(
                data: [pair("i1")], cursor: "cur-1", hasMore: true
            )
        )
        transport.enqueue(
            PaginatedResult<ItemWithMetadata>(
                data: [pair("i2")], cursor: nil, hasMore: false
            )
        )
        transport.enqueue(noEdges())

        let imported = try await engine.performInitialSync()

        #expect(imported == 2)
        let stored = try await store.fetchItems(filters: nil)
        #expect(Set(stored.data.map(\.id)) == ["i1", "i2"])
        // The second page has to be asked for by cursor, not merely fetched.
        let itemCalls = await transport.calls.filter { $0.path == "/items" }
        #expect(itemCalls.count == 2)
        let secondQuery = itemCalls.last?.query ?? []
        #expect(secondQuery.contains { $0.0 == "cursor" && $0.1 == "cur-1" })
    }

    // MARK: - Edges

    @Test("the account's edges are in the store afterwards")
    func importsEdgesIntoTheStore() async throws {
        let (store, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueue(
            PaginatedResult<ItemWithMetadata>(
                data: [pair("i1"), pair("i2")], cursor: nil, hasMore: false
            )
        )
        transport.enqueue(
            PaginatedResult<Edge>(
                data: [edge("e1", from: "i1", to: "i2")], cursor: nil, hasMore: false
            )
        )

        _ = try await engine.performInitialSync()

        // This is the property the whole change exists for. Edge reads resolve
        // against the local store whenever one exists, so an empty edge table
        // means Related, threads and attachments are empty for content the
        // user can plainly see — and SSE never backfills it.
        let outbound = try await store.fetchEdgesFromSource(
            sourceId: "i1", edgeType: nil, cursor: nil, limit: nil
        )
        #expect(outbound.data.map(\.id) == ["e1"])
        #expect(outbound.data.first?.targetId == "i2")
    }

    @Test("the edge pass pages too")
    func importsEdgesPastTheFirstPage() async throws {
        let (store, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueue(noItems())
        transport.enqueue(
            PaginatedResult<Edge>(
                data: [edge("e1", from: "a", to: "b")], cursor: "ecur-1", hasMore: true
            )
        )
        transport.enqueue(
            PaginatedResult<Edge>(
                data: [edge("e2", from: "b", to: "c")], cursor: nil, hasMore: false
            )
        )

        _ = try await engine.performInitialSync()

        let all = try await store.fetchEdges(edgeType: nil, cursor: nil, limit: nil)
        #expect(Set(all.data.map(\.id)) == ["e1", "e2"])
        let edgeCalls = await transport.calls.filter { $0.path == "/edges" }
        #expect(edgeCalls.count == 2)
        #expect(edgeCalls.last?.query?.contains { $0.0 == "cursor" && $0.1 == "ecur-1" } == true)
    }

    @Test("an edge whose items never arrived is stored rather than refused")
    func importsDanglingEdges() async throws {
        let (store, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        // No items at all, and an edge between two ids the store has never
        // seen. This is what makes the pass order irrelevant, and it is why
        // the edge model holds plain id columns instead of relationships.
        transport.enqueue(noItems())
        transport.enqueue(
            PaginatedResult<Edge>(
                data: [edge("e1", from: "absent-1", to: "absent-2")],
                cursor: nil,
                hasMore: false
            )
        )

        _ = try await engine.performInitialSync()

        let all = try await store.fetchEdges(edgeType: nil, cursor: nil, limit: nil)
        #expect(all.data.map(\.id) == ["e1"])
    }

    @Test("the edge page never asks for more than the route allows")
    func edgePageRespectsTheRouteCeiling() async throws {
        let (_, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueue(noItems())
        transport.enqueue(noEdges())

        // 500 is the edge route's ceiling and a larger `limit` is refused, so a
        // caller asking for a bigger page must not have it forwarded verbatim.
        _ = try await engine.performInitialSync(pageSize: 1000)

        let edgeCall = await transport.calls.first { $0.path == "/edges" }
        let limit = edgeCall?.query?.first { $0.0 == "limit" }?.1
        #expect(limit == "500")
    }

    @Test("running it twice leaves one row per item and per edge")
    func importIsIdempotent() async throws {
        let (store, _, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        for _ in 0..<2 {
            transport.enqueue(
                PaginatedResult<ItemWithMetadata>(
                    data: [pair("i1"), pair("i2")], cursor: nil, hasMore: false
                )
            )
            transport.enqueue(
                PaginatedResult<Edge>(
                    data: [edge("e1", from: "i1", to: "i2")], cursor: nil, hasMore: false
                )
            )
        }

        _ = try await engine.performInitialSync()
        _ = try await engine.performInitialSync()

        let items = try await store.fetchItems(filters: nil)
        #expect(items.data.count == 2)
        let edges = try await store.fetchEdges(edgeType: nil, cursor: nil, limit: nil)
        #expect(edges.data.count == 1)
    }
}
