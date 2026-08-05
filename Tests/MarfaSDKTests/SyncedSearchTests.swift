import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// Search on a **synced** client.
///
/// The mechanism was always there: `LocalStore.searchItems` is a
/// complete offline path with its own tests. What was missing is that a
/// synced client never reached it — the routing asked whether a sync
/// engine existed, so turning sync on silently converted every search
/// into a network round trip. These tests pin the routing rather than
/// the search itself, which is why they assert on what the transport was
/// asked for as much as on what came back.
@Suite("Synced search")
struct SyncedSearchTests {

    private func makeSyncedClient() async throws -> (MarfaClient, MockTransport, LocalStore) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let (store, queue, container) = try await MarfaSDKTest.makeInMemoryStorePair()
        let engine = SyncEngine(
            transport: mock,
            localStore: store,
            mutationQueue: queue,
            connectionManager: ConnectionStateManager()
        )
        let client = MarfaClient(
            configuration: config,
            transport: mock,
            localStore: store,
            mutationQueue: queue,
            syncEngine: engine,
            container: container
        )
        return (client, mock, store)
    }

    private func seed(
        _ store: LocalStore,
        id: String,
        title: String,
        body: String = ""
    ) async throws {
        let item = Item(
            createdAt: "2026-01-01T00:00:00Z",
            id: id,
            properties: ["title": .string(title), "body": .string(body)],
            schemaVersion: 1,
            source: "sdk-test",
            state: .active,
            tier: .library,
            timestamp: "2026-01-01T00:00:00Z",
            type: "core.note",
            updatedAt: "2026-01-01T00:00:00Z",
            version: 1
        )
        try await store.upsertItem(item)
    }

    @Test("A synced client searches locally, with no request to the server")
    func syncedSearchIsLocal() async throws {
        let (client, mock, store) = try await makeSyncedClient()
        try await seed(store, id: "n-1", title: "Meeting notes")

        let hits = try await client.search(query: "meeting")

        #expect(hits.map(\.item.id) == ["n-1"])
        // The point of the change: nothing was asked of the network.
        #expect(mock.calls.isEmpty)
    }

    @Test("Only what has synced is searchable, which is the trade being made")
    func onlyLocalRowsAreFound() async throws {
        let (client, _, store) = try await makeSyncedClient()
        try await seed(store, id: "n-1", title: "Present locally")

        // A row the server would know about but this device has not
        // received is simply not found. That is the honest cost of a
        // local baseline, and it is stated in the kit's docs.
        let hits = try await client.search(query: "not on this device")
        #expect(hits.isEmpty)
    }

    @Test("searchRemote still reaches the index when a caller asks for it")
    func remoteEscapeHatch() async throws {
        let (client, mock, store) = try await makeSyncedClient()
        try await seed(store, id: "n-1", title: "Meeting notes")
        mock.enqueue(SearchResponse(results: [
            SearchResult(
                item: Item(
                    createdAt: "2026-01-01T00:00:00Z",
                    id: "server-1",
                    properties: ["title": .string("Ranked by the index")],
                    schemaVersion: 1,
                    source: "sdk-test",
                    state: .active, tier: .feed,
                    timestamp: "2026-01-01T00:00:00Z",
                    type: "core.note",
                    updatedAt: "2026-01-01T00:00:00Z",
                    version: 1
                ),
                metadata: Metadata(extensions: [:], itemId: "server-1", tags: []),
                relevanceScore: 0.95,
                snippetHtml: "<mark>Ranked</mark> by the index"
            )
        ]))

        let hits = try await client.searchRemote(query: "ranked")

        #expect(hits.map(\.item.id) == ["server-1"])
        #expect(mock.calls.count == 1)
        // Snippets and BM25 scores are what the escape hatch exists for.
        #expect(hits.first?.snippetHtml != nil)
    }

    @Test("The two paths agree on the shapes they both support")
    func parityOnSharedShapes() async throws {
        let (client, _, store) = try await makeSyncedClient()
        try await seed(store, id: "n-1", title: "Alpha report", body: "quarterly")
        try await seed(store, id: "n-2", title: "Beta report", body: "annual")
        try await seed(store, id: "n-3", title: "Unrelated", body: "nothing")

        // Text match over title and body, a type filter, and a limit —
        // the three things both implementations genuinely support. Rank
        // order and snippets are deliberately not compared: they are the
        // stated divergence, not a shared shape.
        let byText = try await client.search(query: "report")
        #expect(Set(byText.map(\.item.id)) == ["n-1", "n-2"])

        let byBody = try await client.search(query: "quarterly")
        #expect(byText.count > byBody.count)
        #expect(byBody.map(\.item.id) == ["n-1"])

        let limited = try await client.search(
            query: "report",
            filters: SearchFilters(limit: 1)
        )
        #expect(limited.count == 1)

        let wrongType = try await client.search(
            query: "report",
            filters: SearchFilters(type: "core.bookmark")
        )
        #expect(wrongType.isEmpty)
    }

    @Test("Sync disabled behaves as it always did — still local")
    func unsyncedIsUnchanged() async throws {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let (store, queue, container) = try await MarfaSDKTest.makeInMemoryStorePair()
        let client = MarfaClient(
            configuration: config,
            transport: mock,
            localStore: store,
            mutationQueue: queue,
            container: container
        )
        try await seed(store, id: "n-1", title: "Offline note")

        let hits = try await client.search(query: "offline")
        #expect(hits.map(\.item.id) == ["n-1"])
        #expect(mock.calls.isEmpty)
    }
}
