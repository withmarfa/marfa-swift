import Foundation

// Internal response wrappers — tiny envelopes that the generator could
// technically emit but would add noise for little value. Grouped here so the
// generated wire types stay focused on the payload shapes.

/// Response from single-item endpoints: `{ "item": ..., "metadata"?: ... }`.
struct ItemResponse: Codable, Sendable {
    var item: Item
    var metadata: Metadata?
}

/// Response from GET /items/:id/versions.
struct VersionsResponse: Codable, Sendable {
    let versions: [Version]
}

/// Response from metadata endpoints: `{ "metadata": ... }`.
struct MetadataResponse: Codable, Sendable {
    let metadata: Metadata
}

/// Response from extension endpoints: `{ "extensions": ... }`.
struct ExtensionsResponse: Codable, Sendable {
    let extensions: [String: [String: JSONValue]]
}

/// Response from GET /items/:id/extensions/:namespace.
struct NamespaceResponse: Codable, Sendable {
    let namespace: String
    let data: [String: JSONValue]?
}

/// Response from GET /search: `{ "results": [SearchResult] }`.
struct SearchResponse: Codable, Sendable {
    let results: [SearchResult]
}

/// Response from type-schema endpoints: `{ "type": ... }`.
struct TypeResponse: Codable, Sendable {
    let type: TypeSchema
}

/// Response from GET /webhooks: `{ "webhooks": [Webhook] }`.
struct WebhooksListResponse: Codable, Sendable {
    let webhooks: [Webhook]
}

/// Response from GET /webhooks/:id/deliveries.
struct DeliveriesResponse: Codable, Sendable {
    let deliveries: [WebhookDelivery]
}

/// Response from GET /keys: `{ "keys": [ApiKey] }`.
struct KeysListResponse: Codable, Sendable {
    let keys: [ApiKey]
}

/// Response from single-edge endpoints: `{ "edge": ... }`.
struct EdgeResponse: Codable, Sendable {
    let edge: Edge
}
