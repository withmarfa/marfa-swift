import Foundation

// Internal response wrappers — tiny envelopes that the generator could
// technically emit but would add noise for little value. Grouped here so the
// generated wire types stay focused on the payload shapes.

/// Response from single-item endpoints: `{ "item": ..., "metadata"?: ... }`.
struct ItemResponse: Codable, Sendable {
    var item: Item
    var metadata: Metadata?
    /// Present only when this write resolved a version conflict, which the
    /// server does in the write's own transaction under `conflict=auto`.
    var conflictResolution: ConflictResolution?

    enum CodingKeys: String, CodingKey {
        case item
        case metadata
        case conflictResolution = "conflict_resolution"
    }
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

/// Response from GET /edge-types: `{ "edge_types": [...] }`.
struct EdgeTypesListResponse: Codable, Sendable {
    let edgeTypes: [EdgeType]

    enum CodingKeys: String, CodingKey {
        case edgeTypes = "edge_types"
    }
}

/// Response from POST /edge-types: `{ "edge_type": ... }`.
struct EdgeTypeResponse: Codable, Sendable {
    let edgeType: EdgeType

    enum CodingKeys: String, CodingKey {
        case edgeType = "edge_type"
    }
}

/// A tag with its usage count, returned by `GET /metadata/tags`.
public struct TagWithCount: Codable, Sendable, Hashable {
    public let tag: String
    public let count: Int

    public init(tag: String, count: Int) {
        self.tag = tag
        self.count = count
    }
}

/// Response from GET /metadata/tags: `{ "tags": [{ tag, count }] }`.
struct TagListResponse: Codable, Sendable {
    let tags: [TagWithCount]
}

/// Response from GET /integrations: `{ "data": [Integration] }`.
struct IntegrationsListResponse: Codable, Sendable {
    let data: [Integration]
}

/// Response from GET /connections/:id/lease-tokens: `{ "leases": [LeaseToken] }`.
struct LeaseTokensListResponse: Codable, Sendable {
    let leases: [LeaseToken]
}

/// Response from GET /connections/:id/inbound-webhooks: `{ "inbound_webhooks": [...] }`.
struct InboundWebhooksListResponse: Codable, Sendable {
    let inboundWebhooks: [InboundWebhookSubscription]

    enum CodingKeys: String, CodingKey {
        case inboundWebhooks = "inbound_webhooks"
    }
}

/// Response from GET /connections/:id/inbound-webhooks/:webhook_id/deliveries.
struct InboundWebhookDeliveriesResponse: Codable, Sendable {
    let deliveries: [InboundWebhookDelivery]
}
