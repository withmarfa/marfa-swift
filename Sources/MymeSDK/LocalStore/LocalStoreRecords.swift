import Foundation
import GRDB

// MARK: - ItemRecord

/// SQLite row representation of an ``Item``.
///
/// Properties are JSON-encoded as a `TEXT` column; all other fields map 1:1
/// to SQLite column types. The GRDB `Codable` record stack drives encode/decode.
struct ItemRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "items"

    var id: String
    var type: String
    var state: String
    var propertiesJson: String  // JSON-encoded [String: JSONValue]
    var source: String
    var sourceId: String?
    var origin: String
    var library: Bool
    var version: Int
    var schemaVersion: Int
    var createdAt: String
    var updatedAt: String
    var timestamp: String
    var device: String?
    var captureLatitude: Double?
    var captureLongitude: Double?

    enum CodingKeys: String, CodingKey {
        case id, type, state, source, origin, library, version, device
        case propertiesJson = "properties_json"
        case sourceId = "source_id"
        case schemaVersion = "schema_version"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case timestamp
        case captureLatitude = "capture_latitude"
        case captureLongitude = "capture_longitude"
    }

    // MARK: Conversion

    func toItem() throws -> Item {
        let properties = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(propertiesJson.utf8)
        )
        return Item(
            captureLatitude: captureLatitude,
            captureLongitude: captureLongitude,
            createdAt: createdAt,
            device: device,
            edges: nil,
            id: id,
            library: library,
            origin: Origin(rawValue: origin) ?? .user,
            properties: properties,
            schemaVersion: schemaVersion,
            source: source,
            sourceId: sourceId,
            state: ItemState(rawValue: state) ?? .active,
            timestamp: timestamp,
            type: type,
            updatedAt: updatedAt,
            version: version
        )
    }

    static func from(_ item: Item) throws -> ItemRecord {
        let propertiesData = try JSONEncoder().encode(item.properties)
        guard let propertiesJson = String(data: propertiesData, encoding: .utf8) else {
            throw LocalStoreError.encodingFailure("item properties")
        }
        return ItemRecord(
            id: item.id,
            type: item.type,
            state: item.state.rawValue,
            propertiesJson: propertiesJson,
            source: item.source,
            sourceId: item.sourceId,
            origin: item.origin.rawValue,
            library: item.library,
            version: item.version,
            schemaVersion: item.schemaVersion,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            timestamp: item.timestamp,
            device: item.device,
            captureLatitude: item.captureLatitude,
            captureLongitude: item.captureLongitude
        )
    }
}

// MARK: - EdgeRecord

/// SQLite row representation of an ``Edge``.
struct EdgeRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "edges"

    var id: String
    var sourceId: String
    var targetId: String
    var edgeType: String
    var propertiesJson: String  // JSON-encoded [String: JSONValue]
    var tenantId: String?
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case sourceId = "source_id"
        case targetId = "target_id"
        case edgeType = "edge_type"
        case propertiesJson = "properties_json"
        case tenantId = "tenant_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    // MARK: Conversion

    func toEdge() throws -> Edge {
        let properties = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(propertiesJson.utf8)
        )
        return Edge(
            createdAt: createdAt,
            edgeType: edgeType,
            id: id,
            properties: properties,
            sourceId: sourceId,
            targetId: targetId,
            tenantId: tenantId,
            updatedAt: updatedAt
        )
    }

    static func from(_ edge: Edge) throws -> EdgeRecord {
        let propsData = try JSONEncoder().encode(edge.properties)
        guard let propertiesJson = String(data: propsData, encoding: .utf8) else {
            throw LocalStoreError.encodingFailure("edge properties")
        }
        return EdgeRecord(
            id: edge.id,
            sourceId: edge.sourceId,
            targetId: edge.targetId,
            edgeType: edge.edgeType,
            propertiesJson: propertiesJson,
            tenantId: edge.tenantId,
            createdAt: edge.createdAt,
            updatedAt: edge.updatedAt
        )
    }
}

// MARK: - MetadataRecord

/// SQLite row representation of item ``Metadata``.
struct MetadataRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "item_metadata"

    var itemId: String
    var tagsJson: String  // JSON-encoded [String]
    var extensionsJson: String  // JSON-encoded [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case tagsJson = "tags_json"
        case extensionsJson = "extensions_json"
    }

    // MARK: Conversion

    func toMetadata() throws -> Metadata {
        let tags = try JSONDecoder().decode([String].self, from: Data(tagsJson.utf8))
        let extensions = try JSONDecoder().decode(
            [String: JSONValue].self, from: Data(extensionsJson.utf8)
        )
        return Metadata(extensions: extensions, itemId: itemId, tags: tags)
    }

    static func empty(itemId: String) -> MetadataRecord {
        MetadataRecord(itemId: itemId, tagsJson: "[]", extensionsJson: "{}")
    }

    static func from(_ metadata: Metadata) throws -> MetadataRecord {
        let tagsData = try JSONEncoder().encode(metadata.tags)
        let extData = try JSONEncoder().encode(metadata.extensions)
        guard let tagsJson = String(data: tagsData, encoding: .utf8),
            let extensionsJson = String(data: extData, encoding: .utf8)
        else {
            throw LocalStoreError.encodingFailure("metadata")
        }
        return MetadataRecord(
            itemId: metadata.itemId,
            tagsJson: tagsJson,
            extensionsJson: extensionsJson
        )
    }
}

// MARK: - LocalStoreError

/// Errors thrown by LocalStore operations.
public enum LocalStoreError: Error, Sendable {
    case encodingFailure(String)
    case databaseSetupFailed(String)
}
