// MARK: - Predicate safety
//
// See `Sources/MarfaSDK/LocalStore/Schema/PredicateConventions.swift`.
// `tagsData` and `extensionsData` are opaque to the predicate engine.
// `TagsQuery` and similar callers fetch metadata rows then aggregate
// in Swift — never via predicates over the JSON blobs.

import Foundation
import SwiftData

@Model
final class MarfaMetadataModel {
    /// String id matching the parent `MarfaItemModel.id`. Indexed for the
    /// `WHERE item_id = ?` lookup that drives `fetchMetadata(itemId:)`.
    var itemId: String = ""

    /// JSON-encoded `[String]`. Use the `tags` accessor for typed access.
    /// Defaults to `[]` so the CloudKit "default value" rule is satisfied.
    var tagsData: Data = Data("[]".utf8)

    /// JSON-encoded `[String: JSONValue]` matching the wire shape
    /// `Metadata.extensions`. Each top-level value is conventionally
    /// `.dictionary([String: JSONValue])` (one namespace per key); the
    /// LocalStore unwrap/wrap helpers handle that translation.
    var extensionsData: Data = Data("{}".utf8)

    /// Inverse of `MarfaItemModel.metadata`. The `@Relationship` macro is
    /// declared on the cascade-owning side only (the item) — placing it
    /// on both sides causes a circular reference per Apple's guidance.
    var item: MarfaItemModel?

    init() {}

    // MARK: - Indexes

    #Index<MarfaMetadataModel>([\.itemId])
}

// MARK: - Ergonomic accessors

extension MarfaMetadataModel {
    /// Typed accessor over `tagsData`. Lazy decode; encoded on set. Self-heals
    /// to `[]` if the stored bytes are invalid JSON.
    var tags: [String] {
        get {
            (try? JSONDecoder().decode([String].self, from: tagsData)) ?? []
        }
        set {
            tagsData = (try? JSONEncoder().encode(newValue))
                ?? Data("[]".utf8)
        }
    }

    /// Typed accessor over `extensionsData`. Lazy decode; encoded on set.
    /// Returns the wire-shape `[String: JSONValue]`. Use the LocalStore
    /// unwrap helpers for the namespace-keyed `[String: [String: JSONValue]]`
    /// view that callers of `fetchExtensions` see.
    var extensions: [String: JSONValue] {
        get {
            (try? JSONDecoder().decode([String: JSONValue].self, from: extensionsData))
                ?? [:]
        }
        set {
            extensionsData = (try? JSONEncoder().encode(newValue))
                ?? Data("{}".utf8)
        }
    }
}
