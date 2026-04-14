import Foundation

/// A search result with relevance scoring.
///
/// Hand-written because the shape mixes the generated `Item` and `Metadata`
/// with scalar fields (`relevance_score`, `snippet_html`) inlined per
/// endpoint, and isn't a free-standing component in the OpenAPI spec.
public struct SearchResult: Codable, Sendable {
    public let item: Item
    public let metadata: Metadata
    public let relevanceScore: Double
    public let snippetHtml: String?

    public init(item: Item, metadata: Metadata, relevanceScore: Double, snippetHtml: String? = nil) {
        self.item = item
        self.metadata = metadata
        self.relevanceScore = relevanceScore
        self.snippetHtml = snippetHtml
    }

    enum CodingKeys: String, CodingKey {
        case item, metadata
        case relevanceScore = "relevance_score"
        case snippetHtml = "snippet_html"
    }
}
