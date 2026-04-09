import Foundation

/// A search result with relevance scoring.
public struct SearchResult: Codable, Sendable {
    public let item: Item
    public let metadata: Metadata
    public let relevanceScore: Double
    public let snippetHtml: String?

    enum CodingKeys: String, CodingKey {
        case item, metadata
        case relevanceScore = "relevance_score"
        case snippetHtml = "snippet_html"
    }
}

/// Wire response from GET /search.
struct SearchResponse: Codable, Sendable {
    let results: [SearchResult]
}
