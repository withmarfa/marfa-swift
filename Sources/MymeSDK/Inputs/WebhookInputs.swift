import Foundation

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
