// MARK: - Predicate safety
//
// See `Sources/MymeSDK/LocalStore/Schema/PredicateConventions.swift`.
// Edges deliberately model their endpoints as `String` ids rather than
// `@Relationship` to `MymeItemModel`. This preserves today's GRDB
// behaviour where edges may dangle when an item is purged or has not
// yet arrived via SSE — and keeps every edge predicate compiled against
// stored String columns that are CloudKit-safe.

import Foundation
import SwiftData

@Model
final class MymeEdgeModel {
    /// UUIDv7 string. Logical key.
    var id: String = ""

    /// String id of the source item. May reference an item not present
    /// in the local store (the SDK upserts edges via SSE without checking).
    var sourceId: String = ""

    /// String id of the target item. Same dangling semantics as `sourceId`.
    var targetId: String = ""

    var edgeType: String = ""

    /// JSON-encoded `[String: JSONValue]`. See `properties` accessor.
    var propertiesData: Data = Data("{}".utf8)

    var tenantId: String?

    /// ISO 8601 with fractional seconds.
    var createdAt: String = ""
    var updatedAt: String = ""

    init() {}

    // MARK: - Indexes

    #Index<MymeEdgeModel>(
        [\.id],
        [\.sourceId, \.edgeType],
        [\.targetId, \.edgeType]
    )
}

// MARK: - Ergonomic accessors

extension MymeEdgeModel {
    /// Typed accessor over `propertiesData`. See the `MymeItemModel.properties`
    /// docs for the same lazy-decode + self-heal contract.
    var properties: [String: JSONValue] {
        get {
            (try? JSONDecoder().decode([String: JSONValue].self, from: propertiesData))
                ?? [:]
        }
        set {
            propertiesData = (try? JSONEncoder().encode(newValue))
                ?? Data("{}".utf8)
        }
    }
}
