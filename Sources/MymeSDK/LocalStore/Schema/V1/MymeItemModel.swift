// MARK: - Predicate safety
//
// See `Sources/MymeSDK/LocalStore/Schema/PredicateConventions.swift` for the
// full ruleset. Highlights enforced here:
//  - Codable enums (`state`) persist as `String` rawValue properties
//    (`stateRaw`). Predicates compare against the rawValue, never against an
//    enum case.
//  - `propertiesData` is opaque to the predicate engine — fetch then filter
//    in Swift if you need to reach inside.
//  - `metadata` is the cascade-owning side of the 1:1 relationship to
//    `MymeMetadataModel`. The inverse is declared here only.

import Foundation
import SwiftData

@Model
final class MymeItemModel {
    /// UUIDv7 string. The logical key — uniqueness is enforced by construction
    /// at every callsite that creates an item. No `@Attribute(.unique)` —
    /// CloudKit silently refuses uniqueness constraints.
    var id: String = ""

    var type: String = ""

    /// Stored as the `String` rawValue of `ItemState`. Use `state` for ergonomic
    /// access; predicate against `stateRaw`.
    var stateRaw: String = ItemState.active.rawValue

    /// JSON-encoded `[String: JSONValue]`. Defaults to an empty object so the
    /// CloudKit-required "every property has a default" rule is satisfied.
    /// Decode/encode through the `properties` computed accessor.
    var propertiesData: Data = Data("{}".utf8)

    var source: String = ""
    var sourceId: String?

    /// Stored as the `String` rawValue of `Tier`. Empty string means
    /// "no tier" — `system.*` items have no tier, mirroring the wire.
    var tierRaw: String = ""
    var version: Int = 1
    var schemaVersion: Int = 1

    /// ISO 8601 with fractional seconds (CLAUDE.md: dates as strings).
    var createdAt: String = ""
    var updatedAt: String = ""
    var timestamp: String = ""

    var device: String?
    var captureLatitude: Double?
    var captureLongitude: Double?

    /// 1:1 satellite metadata row. Cascade so `purgeItem` is one delete + one
    /// save. Inverse declared here only — never on both sides.
    @Relationship(deleteRule: .cascade, inverse: \MymeMetadataModel.item)
    var metadata: MymeMetadataModel?

    init() {}

    // MARK: - Indexes

    #Index<MymeItemModel>([\.id], [\.type, \.stateRaw], [\.updatedAt])
}

// MARK: - Ergonomic accessors

extension MymeItemModel {
    /// Typed accessor for `stateRaw`. Falls back to `.active` if the stored
    /// rawValue ever drifts off the closed set (defensive against forward
    /// schema drift on a CloudKit-mirrored store).
    var state: ItemState {
        get { ItemState(rawValue: stateRaw) ?? .active }
        set { stateRaw = newValue.rawValue }
    }

    /// Typed accessor for `tierRaw`. Empty `tierRaw` (the default) maps
    /// to `nil` — `system.*` items have no tier. Setting `nil` clears
    /// the field.
    var tier: Tier? {
        get { Tier(rawValue: tierRaw) }
        set { tierRaw = newValue?.rawValue ?? "" }
    }

    /// Typed accessor over `propertiesData`. Decodes lazily on get; re-encodes
    /// on set. If the stored bytes are invalid JSON the getter returns `[:]`
    /// and the model self-heals on the next mutation.
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
