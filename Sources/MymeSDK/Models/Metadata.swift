import Foundation

/// Metadata sidecar for an item: tags, entity references, and extensions.
public struct Metadata: Codable, Sendable, Hashable {
    public let itemId: String
    public let tags: [String]
    public let about: [String]
    public let extensions: [String: [String: JSONValue]]

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case tags, about, extensions
    }

    public init(itemId: String, tags: [String] = [], about: [String] = [], extensions: [String: [String: JSONValue]] = [:]) {
        self.itemId = itemId
        self.tags = tags
        self.about = about
        self.extensions = extensions
    }
}

/// Input for metadata set/merge operations.
public struct MetadataInput: Codable, Sendable {
    public var tags: [String]?
    public var about: [String]?

    public init(tags: [String]? = nil, about: [String]? = nil) {
        self.tags = tags
        self.about = about
    }
}

// MARK: - Wire response wrappers

/// Response from metadata endpoints: `{ "metadata": ... }`.
struct MetadataResponse: Codable, Sendable {
    let metadata: Metadata
}

/// Body for POST /items/:id/tags.
struct AddTagsBody: Codable, Sendable {
    let tags: [String]
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
