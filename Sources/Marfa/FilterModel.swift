import Foundation
internal import MarfaCore

/// A listing's `filter`, as typed values: one or more conditions joined by `all` or `any`.
///
/// The core writes and reads the grammar, so an app quotes nothing, counts no length and parses no saved filter. Put
/// the text ``encoded()`` gives in a `filter` field, such as ``ListFilters/filter``, and read a saved one back with
/// ``init(decoding:)``. The `filter` fields stay text because a saved view or folder holds the text it was saved with,
/// and reading one must not fail for a filter this build cannot parse.
public struct FilterExpression: Sendable, Hashable {
    public var join: FilterJoin
    public var conditions: [FilterCondition]

    public init(join: FilterJoin = .all, conditions: [FilterCondition]) {
        self.join = join
        self.conditions = conditions
    }

    /// The expression a filter text holds.
    ///
    /// Throws `validation` with the server's code and message for a text the server refuses. A single condition
    /// reads back with the join ``FilterJoin/all``, whichever join wrote it.
    public init(decoding text: String) throws {
        self.init(try translated { try MarfaCore.decodeFilter(text: text) })
    }

    /// The expression's text in the listing grammar.
    ///
    /// Throws `validation` with the server's code and message where the server would refuse the text, such as for one
    /// over 2,048 UTF-16 code units.
    public func encoded() throws -> String {
        try translated { try MarfaCore.encodeFilter(expression: core) }
    }

    init(_ core: MarfaCore.FilterExpression) {
        self.init(join: FilterJoin(core.join), conditions: core.conditions.map(FilterCondition.init))
    }

    var core: MarfaCore.FilterExpression {
        MarfaCore.FilterExpression(join: join.core, conditions: conditions.map(\.core))
    }
}

/// How the conditions of a ``FilterExpression`` combine.
public enum FilterJoin: Sendable, Hashable, CaseIterable {
    /// Every condition holds.
    case all
    /// At least one condition holds.
    case any

    init(_ core: MarfaCore.FilterJoin) {
        switch core {
        case .all: self = .all
        case .any: self = .any
        }
    }

    var core: MarfaCore.FilterJoin {
        switch self {
        case .all: .all
        case .any: .any
        }
    }
}

/// One condition: a field, an operator and a value.
public struct FilterCondition: Sendable, Hashable {
    public var field: FilterField
    public var `operator`: FilterOperator
    /// `nil` exactly where the operator takes none: ``FilterOperator/exists`` and ``FilterOperator/notExists``.
    public var value: FilterValue?

    public init(field: FilterField, operator: FilterOperator, value: FilterValue? = nil) {
        self.field = field
        self.operator = `operator`
        self.value = value
    }

    init(_ core: MarfaCore.FilterCondition) {
        self.init(
            field: FilterField(core.field), operator: FilterOperator(core.operator),
            value: core.value.map(FilterValue.init))
    }

    var core: MarfaCore.FilterCondition {
        MarfaCore.FilterCondition(field: field.core, operator: `operator`.core, value: value?.core)
    }
}

/// What a condition tests.
public enum FilterField: Sendable, Hashable {
    case system(SystemField)
    /// An item property, by name.
    case property(String)
    /// A member of a property that holds an object, such as a field's `amount`.
    case member(field: String, member: String)
    case tags
    /// The group of an item's status word.
    case statusGroup
    /// Whether the item is a part of a host outside the bin.
    case part
    /// The items at the other end of an edge of one type.
    case edge(type: String, direction: EdgeDirection)

    /// The operators the grammar takes on this field.
    public var operators: [FilterOperator] {
        MarfaCore.filterOperators(field: core).map(FilterOperator.init)
    }

    init(_ core: MarfaCore.FilterField) {
        switch core {
        case .system(let name): self = .system(SystemField(name))
        case .property(let name): self = .property(name)
        case .member(let field, let member): self = .member(field: field, member: member)
        case .tags: self = .tags
        case .statusGroup: self = .statusGroup
        case .part: self = .part
        case .edge(let edgeType, let direction): self = .edge(type: edgeType, direction: EdgeDirection(direction))
        }
    }

    var core: MarfaCore.FilterField {
        switch self {
        case .system(let name): .system(name: name.core)
        case .property(let name): .property(name: name)
        case .member(let field, let member): .member(field: field, member: member)
        case .tags: .tags
        case .statusGroup: .statusGroup
        case .part: .part
        case .edge(let type, let direction): .edge(edgeType: type, direction: direction.core)
        }
    }
}

/// A field every item has.
public enum SystemField: Sendable, Hashable, CaseIterable {
    case state
    case type
    case source
    case occurredAt
    case createdAt
    case updatedAt
    case tier
    case version
    case id
    case sourceId

    init(_ core: MarfaCore.SystemField) {
        switch core {
        case .state: self = .state
        case .type: self = .type
        case .source: self = .source
        case .occurredAt: self = .occurredAt
        case .createdAt: self = .createdAt
        case .updatedAt: self = .updatedAt
        case .tier: self = .tier
        case .version: self = .version
        case .id: self = .id
        case .sourceId: self = .sourceId
        }
    }

    var core: MarfaCore.SystemField {
        switch self {
        case .state: .state
        case .type: .type
        case .source: .source
        case .occurredAt: .occurredAt
        case .createdAt: .createdAt
        case .updatedAt: .updatedAt
        case .tier: .tier
        case .version: .version
        case .id: .id
        case .sourceId: .sourceId
        }
    }
}

/// Which end of an edge the filtered item stands at.
public enum EdgeDirection: Sendable, Hashable, CaseIterable {
    /// The item is the edge's source.
    case outbound
    /// The item is the edge's target.
    case backref

    init(_ core: MarfaCore.EdgeDirection) {
        switch core {
        case .outbound: self = .outbound
        case .backref: self = .backref
        }
    }

    var core: MarfaCore.EdgeDirection {
        switch self {
        case .outbound: .outbound
        case .backref: .backref
        }
    }
}

public enum FilterOperator: Sendable, Hashable, CaseIterable {
    case eq
    case neq
    case gt
    case gte
    case lt
    case lte
    case contains
    case startsWith
    /// Takes no value.
    case exists
    /// Takes no value.
    case notExists

    init(_ core: MarfaCore.FilterOperator) {
        switch core {
        case .eq: self = .eq
        case .neq: self = .neq
        case .gt: self = .gt
        case .gte: self = .gte
        case .lt: self = .lt
        case .lte: self = .lte
        case .contains: self = .contains
        case .startsWith: self = .startsWith
        case .exists: self = .exists
        case .notExists: self = .notExists
        }
    }

    var core: MarfaCore.FilterOperator {
        switch self {
        case .eq: .eq
        case .neq: .neq
        case .gt: .gt
        case .gte: .gte
        case .lt: .lt
        case .lte: .lte
        case .contains: .contains
        case .startsWith: .startsWith
        case .exists: .exists
        case .notExists: .notExists
        }
    }
}

public enum FilterValue: Sendable, Hashable {
    case text(String)
    case number(Double)
    case bool(Bool)

    init(_ core: MarfaCore.FilterValue) {
        switch core {
        case .text(let value): self = .text(value)
        case .number(let value): self = .number(value)
        case .bool(let value): self = .bool(value)
        }
    }

    var core: MarfaCore.FilterValue {
        switch self {
        case .text(let value): .text(value: value)
        case .number(let value): .number(value: value)
        case .bool(let value): .bool(value: value)
        }
    }
}
