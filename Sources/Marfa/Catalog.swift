import Foundation
import MarfaCore
import MarfaCoreNames

/// The server's item type and edge type definitions, as the copy holds them,
/// custom types included.
///
/// Every read answers from the store alone, with no request, so a copy
/// answers offline and a reader answers as the writer does. A hydration
/// replaces both catalogs with the server's; a catch-up, and a held
/// `changes()` stream each time it opens, read them again. Each time one of
/// those changes either catalog, `Status.catalogVersion` moves, and a held
/// stream is told `.refreshed(.catalog)`, or `.refreshed(.hydrated)` for a
/// hydration, which replaces the catalogs with everything else.
///
/// On a copy that has never held a catalog every read throws `noCatalog`,
/// never an empty list. An id the catalog does not hold throws `notFound`,
/// with the code `type_not_found` or `edge_type_not_found`.
public struct Catalog: Sendable {
    let core: Core

    /// By id.
    public func itemTypes() async throws -> [ItemType] {
        try await background { [core] in try core.itemTypes().map(ItemType.init) }
    }

    public func itemType(_ id: String) async throws -> ItemType {
        try await background { [core] in try ItemType(core.itemType(id: id)) }
    }

    /// By id.
    public func edgeTypes() async throws -> [EdgeType] {
        try await background { [core] in try core.edgeTypes().map(EdgeType.init) }
    }

    public func edgeType(_ id: String) async throws -> EdgeType {
        try await background { [core] in try EdgeType(core.edgeType(id: id)) }
    }
}

/// An item type, read as the server's `GET /types/{id}` answers it.
public struct ItemType: Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String?
    public let description: String?
    public let parent: String?
    public let version: Int64
    /// By name, with the fields it inherits; a field declared again nearer
    /// this type takes the place of the one above it.
    public let fields: [TypeField]
    /// The title and body hints are those of the nearest type that declares
    /// any, taken whole: a subtype naming only its body has no title field.
    public let titleField: String?
    public let bodyField: String?
    /// The field holding each row's own id at the vendor that writes rows of
    /// exactly this type.
    public let linkField: String?
    public let roles: [String]
    /// The sibling types this one asserts a structural superset of.
    public let compatibleWith: [String]

    /// For an app's previews and tests.
    public init(
        id: String, label: String? = nil, description: String? = nil, parent: String? = nil, version: Int64 = 0,
        fields: [TypeField] = [], titleField: String? = nil, bodyField: String? = nil, linkField: String? = nil,
        roles: [String] = [], compatibleWith: [String] = []
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.parent = parent
        self.version = version
        self.fields = fields
        self.titleField = titleField
        self.bodyField = bodyField
        self.linkField = linkField
        self.roles = roles
        self.compatibleWith = compatibleWith
    }

    init(_ core: CoreItemType) throws {
        self.init(
            id: core.id, label: core.label, description: core.description, parent: core.parent,
            version: core.version, fields: try core.fields.map(TypeField.init), titleField: core.titleField,
            bodyField: core.bodyField, linkField: core.linkField, roles: core.roles,
            compatibleWith: core.compatibleWith)
    }
}

/// A field of an item type, or a property of an edge type.
public struct TypeField: Sendable, Hashable, Identifiable {
    public let name: String
    /// The field's own type, such as `string` or `thumbnail`.
    public let type: String
    public let required: Bool
    public let description: String?
    /// The type that declares it: the type itself, or the nearest one it
    /// inherits the field from.
    public let declaredBy: String
    /// The definition whole, as the server holds it.
    public let definition: [String: JSONValue]

    public var id: String { name }

    /// For an app's previews and tests.
    public init(
        name: String, type: String, required: Bool = false, description: String? = nil, declaredBy: String,
        definition: [String: JSONValue] = [:]
    ) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
        self.declaredBy = declaredBy
        self.definition = definition
    }

    init(_ core: CoreTypeField) throws {
        self.init(
            name: core.name, type: core.fieldType, required: core.required, description: core.description,
            declaredBy: core.declaredBy, definition: try Properties.object(core.definitionJson))
    }
}

/// The end of an edge whose file writes it.
public enum EdgeEnd: Sendable, Hashable, CaseIterable {
    case source
    case target

    init(_ core: CoreEdgeEnd) {
        switch core {
        case .source: self = .source
        case .target: self = .target
        }
    }

    var core: CoreEdgeEnd {
        switch self {
        case .source: .source
        case .target: .target
        }
    }
}

/// An edge type, read as the server's `GET /edge-types` lists it.
public struct EdgeType: Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String?
    public let description: String?
    /// `one-to-one`, `one-to-many`, `many-to-one` or `many-to-many`, from
    /// source to target.
    public let cardinality: String
    /// The name the edge goes by read from its target.
    public let reverseName: String?
    public let writtenAt: EdgeEnd
    public let sourceTypeConstraints: [String]
    public let targetTypeConstraints: [String]
    /// `cascade`, `orphan` or `block`.
    public let cascadeOnDelete: String
    /// By name.
    public let properties: [TypeField]
    /// Whether Marfa ships it, rather than the instance registering it.
    public let shipped: Bool

    /// For an app's previews and tests.
    public init(
        id: String, label: String? = nil, description: String? = nil, cardinality: String,
        reverseName: String? = nil, writtenAt: EdgeEnd = .source, sourceTypeConstraints: [String] = ["*"],
        targetTypeConstraints: [String] = ["*"], cascadeOnDelete: String = "orphan", properties: [TypeField] = [],
        shipped: Bool = false
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.cardinality = cardinality
        self.reverseName = reverseName
        self.writtenAt = writtenAt
        self.sourceTypeConstraints = sourceTypeConstraints
        self.targetTypeConstraints = targetTypeConstraints
        self.cascadeOnDelete = cascadeOnDelete
        self.properties = properties
        self.shipped = shipped
    }

    init(_ core: CoreEdgeType) throws {
        self.init(
            id: core.id, label: core.label, description: core.description, cardinality: core.cardinality,
            reverseName: core.reverseName, writtenAt: EdgeEnd(core.writtenAt),
            sourceTypeConstraints: core.sourceTypeConstraints, targetTypeConstraints: core.targetTypeConstraints,
            cascadeOnDelete: core.cascadeOnDelete, properties: try core.properties.map(TypeField.init),
            shipped: core.shipped)
    }
}
