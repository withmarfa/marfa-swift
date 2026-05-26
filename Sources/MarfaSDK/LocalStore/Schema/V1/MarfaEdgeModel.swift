// MARK: - Predicate safety
//
// See `Sources/MarfaSDK/LocalStore/Schema/PredicateConventions.swift`.
// Edges deliberately model their endpoints as `String` ids rather than
// `@Relationship` to `MarfaItemModel`. Edges may dangle when an item is
// purged or has not yet arrived via SSE; the SDK upserts edges from
// the server stream without checking that their endpoints exist
// locally. String-id columns also keep every edge predicate
// CloudKit-safe (no relationship traversal in the predicate engine).

import Foundation
import SwiftData

@Model
final class MarfaEdgeModel {
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

    #Index<MarfaEdgeModel>(
        [\.id],
        [\.sourceId, \.edgeType],
        [\.targetId, \.edgeType]
    )
}

// MARK: - Ergonomic accessors

extension MarfaEdgeModel {
    /// Typed accessor over `propertiesData`. See the `MarfaItemModel.properties`
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
