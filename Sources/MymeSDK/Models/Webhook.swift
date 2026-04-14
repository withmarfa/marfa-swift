import Foundation

/// A registered webhook.
public struct Webhook: Codable, Sendable, Identifiable {
    public let id: String
    public let url: String
    public let secret: String
    public let events: [String]
    public let typeFilter: String?
    public let active: Bool
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, url, secret, events, active
        case typeFilter = "type_filter"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// A webhook delivery attempt.
public struct WebhookDelivery: Codable, Sendable, Identifiable {
    public let id: String
    public let webhookId: String
    public let event: String
    public let statusCode: Int?
    public let attempt: Int
    public let success: Bool
    public let error: String?
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, event, attempt, success, error
        case webhookId = "webhook_id"
        case statusCode = "status_code"
        case createdAt = "created_at"
    }
}
