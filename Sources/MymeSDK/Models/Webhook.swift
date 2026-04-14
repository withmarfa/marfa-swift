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

/// Input for creating a webhook.
public struct CreateWebhookInput: Codable, Sendable {
    public var url: String
    public var events: [String]
    public var typeFilter: String?
    public var secret: String?

    public init(url: String, events: [String], typeFilter: String? = nil, secret: String? = nil) {
        self.url = url
        self.events = events
        self.typeFilter = typeFilter
        self.secret = secret
    }

    enum CodingKeys: String, CodingKey {
        case url, events, secret
        case typeFilter = "type_filter"
    }
}

/// Input for updating a webhook.
public struct UpdateWebhookInput: Codable, Sendable {
    public var url: String?
    public var events: [String]?
    public var typeFilter: String?
    public var active: Bool?

    public init(url: String? = nil, events: [String]? = nil, typeFilter: String? = nil, active: Bool? = nil) {
        self.url = url
        self.events = events
        self.typeFilter = typeFilter
        self.active = active
    }

    enum CodingKeys: String, CodingKey {
        case url, events, active
        case typeFilter = "type_filter"
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

