import Foundation

/// One edge-type bucket inside `Item.edges`. The server groups outbound edges
/// by type and returns each group with its own pagination cursor.
public struct ItemEdgeGroup: Codable, Sendable, Hashable {
    public let edges: [Edge]
    public let hasMore: Bool
    public let nextCursor: String?

    public init(
        edges: [Edge],
        hasMore: Bool,
        nextCursor: String? = nil
    ) {
        self.edges = edges
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }

    enum CodingKeys: String, CodingKey {
        case edges
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }
}
