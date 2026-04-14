import Foundation

/// A thread for sequential grouping of items.
public struct MymeThread: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
