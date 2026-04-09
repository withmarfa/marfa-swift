import Testing
import Foundation
@testable import MymeSDK

@Suite("Search")
struct SearchTests {

    func makeClient() -> (MymeClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let client = MymeClient(configuration: config, transport: mock)
        return (client, mock)
    }

    @Test("Search sends GET /search with query param")
    func searchItems() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(SearchResponse(results: [
            SearchResult(
                item: Item(
                    id: "found-1", type: "core.note", state: .active,
                    properties: ["title": .string("Found")],
                    createdAt: "2026-01-01T00:00:00Z",
                    updatedAt: "2026-01-01T00:00:00Z",
                    timestamp: "2026-01-01T00:00:00Z",
                    source: nil, sourceId: nil, origin: nil, version: 1,
                    schemaVersion: nil, deviceId: nil, parentId: nil,
                    threadId: nil, captureLatitude: nil, captureLongitude: nil
                ),
                metadata: Metadata(itemId: "found-1", tags: [], about: [], extensions: [:]),
                relevanceScore: 0.95,
                snippetHtml: "<mark>Found</mark> in title"
            ),
        ]))

        let results = try await client.search(query: "found")

        #expect(results.count == 1)
        #expect(results[0].item.id == "found-1")
        #expect(results[0].relevanceScore == 0.95)
        #expect(mock.calls[0].path == "/search")
        #expect(mock.calls[0].query?.contains(where: { $0.0 == "q" && $0.1 == "found" }) == true)
    }

    @Test("Search with filters includes filter params")
    func searchWithFilters() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(SearchResponse(results: []))

        _ = try await client.search(
            query: "test",
            filters: SearchFilters(type: "core.note", limit: 5)
        )

        let query = mock.calls[0].query!
        #expect(query.contains(where: { $0.0 == "type" && $0.1 == "core.note" }))
        #expect(query.contains(where: { $0.0 == "limit" && $0.1 == "5" }))
    }
}
