import Foundation

/// Input shape for `POST /edge-types` — custom edge-type registration.
///
/// Admin-only on the server: attempts from a non-admin key return 403.
/// Matches the TypeScript SDK's `EdgeTypeSchema` shape so the two SDKs
/// register the same surface.
public struct CreateEdgeTypeInput: Codable, Sendable {
    /// Edge-type identifier, e.g. `"team.commented-on"`. Must not collide with
    /// a core edge type.
    public let id: String

    /// Human-readable label, displayed in tooling.
    public let label: String?

    /// Longer description of the relationship.
    public let description: String?

    /// Cardinality of the relationship.
    public let cardinality: EdgeTypeCardinality

    /// Valid source-side types. Empty or unset means "any type".
    /// Inheritance-aware: subtypes satisfy an ancestor constraint.
    public let sourceTypeConstraints: [String]?

    /// Valid target-side types. Same semantics as ``sourceTypeConstraints``.
    public let targetTypeConstraints: [String]?

    /// What happens when an endpoint item is deleted.
    /// Defaults to `.orphan` when unset.
    public let cascadeOnDelete: EdgeTypeCascadeOnDelete?

    /// Schema for allowed `properties` on edges of this type. Empty map
    /// means no validated properties; the server rejects any properties
    /// passed on this type's edges.
    public let propertySchema: [String: FieldDefinition]?

    public init(
        id: String,
        cardinality: EdgeTypeCardinality,
        label: String? = nil,
        description: String? = nil,
        sourceTypeConstraints: [String]? = nil,
        targetTypeConstraints: [String]? = nil,
        cascadeOnDelete: EdgeTypeCascadeOnDelete? = nil,
        propertySchema: [String: FieldDefinition]? = nil
    ) {
        self.id = id
        self.cardinality = cardinality
        self.label = label
        self.description = description
        self.sourceTypeConstraints = sourceTypeConstraints
        self.targetTypeConstraints = targetTypeConstraints
        self.cascadeOnDelete = cascadeOnDelete
        self.propertySchema = propertySchema
    }

    enum CodingKeys: String, CodingKey {
        case id, label, description, cardinality
        case sourceTypeConstraints = "source_type_constraints"
        case targetTypeConstraints = "target_type_constraints"
        case cascadeOnDelete = "cascade_on_delete"
        case propertySchema = "property_schema"
    }
}
