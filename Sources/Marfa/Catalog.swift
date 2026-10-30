import Foundation
import MarfaCore

/// The item type and edge type definitions the copy holds, custom types included.
///
/// Every read answers from the store alone, with no request, so a copy
/// answers offline and a reader answers as the writer does. A hydration
/// replaces both catalogs with the server's; a catch-up, and a held
/// `changes()` stream each time it opens, read them again. Each time one of
/// those changes either catalog, `Status.catalogVersion` moves, and a held
/// stream is told `.refreshed(.catalog)`, or `.refreshed(.hydrated)` for a
/// hydration, which replaces the catalogs with everything else.
///
/// Before its first hydration, a copy holds Marfa's built-in catalog and the
/// app's declared item types. An id the catalog does not hold throws `notFound`,
/// with the code `type_not_found` or `edge_type_not_found`.
public struct Catalog: Sendable {
    let holder: CoreHolder

    /// By id.
    public func itemTypes() async throws -> [ItemType] {
        try await holder.run { core in try core.itemTypes().map(ItemType.init) }
    }

    public func itemType(_ id: String) async throws -> ItemType {
        try await holder.run { core in ItemType(try core.itemType(id: id)) }
    }

    /// By id.
    public func edgeTypes() async throws -> [EdgeType] {
        try await holder.run { core in try core.edgeTypes().map(EdgeType.init) }
    }

    public func edgeType(_ id: String) async throws -> EdgeType {
        try await holder.run { core in EdgeType(try core.edgeType(id: id)) }
    }

    /// The server's item types and edge types, read from it now.
    ///
    /// An app can offer a choice of types before a first hydration. Nothing in the copy changes, and the other reads here keep answering from the store.
    ///
    /// Throws `noServer` for a copy opened without a server, and `network` when the server cannot be reached.
    /// Canceling the task ends the request with `canceled`.
    public func fromServer() async throws -> ServerCatalog {
        try await holder.runUntilCanceled { core, stop in
            ServerCatalog(try core.serverCatalog(stop: stop))
        }
    }
}

/// What the server holds, as ``Catalog/fromServer()`` reads it.
public struct ServerCatalog: Sendable, Hashable {
    /// By id.
    public let itemTypes: [ItemType]
    /// By id.
    public let edgeTypes: [EdgeType]

    /// For an app's previews and tests.
    public init(itemTypes: [ItemType] = [], edgeTypes: [EdgeType] = []) {
        self.itemTypes = itemTypes
        self.edgeTypes = edgeTypes
    }

    init(_ core: MarfaCore.ServerCatalog) {
        self.init(itemTypes: core.itemTypes.map(ItemType.init), edgeTypes: core.edgeTypes.map(EdgeType.init))
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
    /// Each display hint comes from the nearest type that sets it: a subtype
    /// naming only its body keeps its parent's title field.
    public let titleField: String?
    public let bodyField: String?
    /// The Iconify ID of the icon that stands for the type, `<set>:<name>`
    /// such as `lucide:book-open` or `simple-icons:github`; `nil` when no
    /// type in its chain sets one.
    ///
    /// The core has resolved it: the owner's own choice for this type or the
    /// nearest type that has one, else the nearest author's. A server newer
    /// than the SDK can send an ID the SDK does not know; `MarfaIcons` draws
    /// a fallback for it.
    public let icon: String?
    /// The field holding each row's own id at the vendor that writes rows of
    /// exactly this type.
    public let linkField: String?
    public let roles: [String]
    /// The sibling types this one asserts a structural superset of.
    public let compatibleWith: [String]

    /// For an app's previews and tests.
    public init(
        id: String, label: String? = nil, description: String? = nil, parent: String? = nil, version: Int64 = 0,
        fields: [TypeField] = [], titleField: String? = nil, bodyField: String? = nil, icon: String? = nil,
        linkField: String? = nil, roles: [String] = [], compatibleWith: [String] = []
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.parent = parent
        self.version = version
        self.fields = fields
        self.titleField = titleField
        self.bodyField = bodyField
        self.icon = icon
        self.linkField = linkField
        self.roles = roles
        self.compatibleWith = compatibleWith
    }

    init(_ core: MarfaCore.ItemType) {
        self.init(
            id: core.id, label: core.label, description: core.description, parent: core.parent,
            version: core.version, fields: core.fields.map(TypeField.init), titleField: core.titleField,
            bodyField: core.bodyField, icon: core.icon, linkField: core.linkField, roles: core.roles,
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
    public let definition: JSONObject

    public var id: String { name }

    /// For an app's previews and tests.
    public init(
        name: String, type: String, required: Bool = false, description: String? = nil, declaredBy: String,
        definition: JSONObject = [:]
    ) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
        self.declaredBy = declaredBy
        self.definition = definition
    }

    init(_ core: MarfaCore.TypeField) {
        self.init(
            name: core.name, type: core.fieldType, required: core.required, description: core.description,
            declaredBy: core.declaredBy, definition: core.definition)
    }
}

/// Where a folder writes an edge: in its source item's file, in its target
/// item's file under the edge type's reverse name, or in none.
public enum EdgeWrittenAt: Sendable, Hashable, CaseIterable {
    case source
    case target
    /// No file writes the edge, as for a file's placement in a folder.
    case none

    init(_ core: MarfaCore.EdgeWrittenAt) {
        switch core {
        case .source: self = .source
        case .target: self = .target
        case .none: self = .none
        }
    }
}

/// An edge type, read as the server's `GET /edge-types` lists it.
public struct EdgeType: Sendable, Hashable, Identifiable {
    public let id: String
    /// The name shown on the source end.
    ///
    /// The server derives one from the id for a type registered with none.
    public let label: String
    /// The name shown on the target end.
    ///
    /// It is the ``label`` for a two-way relation, which has no reverse label of its own.
    public let reverseLabel: String
    public let description: String?
    /// `one-to-one`, `one-to-many`, `many-to-one` or `many-to-many`, from
    /// source to target.
    public let cardinality: String
    /// The name the edge goes by read from its target.
    public let reverseName: String?
    public let writtenAt: EdgeWrittenAt
    public let sourceTypeConstraints: [String]
    public let targetTypeConstraints: [String]
    /// `cascade`, `orphan` or `block`.
    public let cascadeOnDelete: String
    /// By name.
    public let properties: [TypeField]
    /// Whether Marfa ships it, rather than the instance registering it.
    public let shipped: Bool

    /// For an app's previews and tests; `reverseLabel` is `label` where it is `nil`, as the server answers it.
    public init(
        id: String, label: String, reverseLabel: String? = nil, description: String? = nil, cardinality: String,
        reverseName: String? = nil, writtenAt: EdgeWrittenAt = .source, sourceTypeConstraints: [String] = ["*"],
        targetTypeConstraints: [String] = ["*"], cascadeOnDelete: String = "orphan", properties: [TypeField] = [],
        shipped: Bool = false
    ) {
        self.id = id
        self.label = label
        self.reverseLabel = reverseLabel ?? label
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

    init(_ core: MarfaCore.EdgeType) {
        self.init(
            id: core.id, label: core.label, reverseLabel: core.reverseLabel, description: core.description,
            cardinality: core.cardinality, reverseName: core.reverseName, writtenAt: EdgeWrittenAt(core.writtenAt),
            sourceTypeConstraints: core.sourceTypeConstraints, targetTypeConstraints: core.targetTypeConstraints,
            cascadeOnDelete: core.cascadeOnDelete, properties: core.properties.map(TypeField.init),
            shipped: core.shipped)
    }
}
