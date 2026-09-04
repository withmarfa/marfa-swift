import Foundation

/// What a field may hold, as the platform type registry declares it.
///
/// The cases are the server's vocabulary rather than Swift's: `integer` is
/// distinct from `number` because the server checks it, and `url`, `email`,
/// `datetime` and `date` are string shapes with a format the server enforces
/// rather than free text. A value the device cannot check is worse than no
/// check at all, because it produces a write the person believes is queued
/// and the server refuses hours later.
public enum MarfaFieldType: String, Sendable, Codable, CaseIterable {
    case string
    case number
    case integer
    case boolean
    case url
    case email
    case datetime
    case date
    case explicitEnum = "enum"
    case array
    case object
}

/// One field on a type, as the registry declares it.
public struct MarfaFieldDefinition: Sendable, Equatable, Codable {
    public let type: MarfaFieldType
    /// Permitted values, for an `enum` field. An enum declaring none falls
    /// back to a plain string, which is what the server does.
    public let enumValues: [String]?
    /// Upper bound on an `array` field's element count.
    public let maxItems: Int?
    /// Upper bound on a string field's length.
    public let maxLength: Int?
    /// Whether the type lists this field under `required`.
    public let isRequired: Bool

    public init(
        type: MarfaFieldType,
        enumValues: [String]? = nil,
        maxItems: Int? = nil,
        maxLength: Int? = nil,
        isRequired: Bool = false
    ) {
        self.type = type
        self.enumValues = enumValues
        self.maxItems = maxItems
        self.maxLength = maxLength
        self.isRequired = isRequired
    }
}

/// A type in the graph, with its parent chain already flattened.
///
/// `fields` carries the type's own fields *and* every inherited one, because
/// that is the set a write is validated against and resolving the chain at
/// validation time would mean walking it on every call. `parent` is kept so a
/// query for a parent type can find its descendants.
public struct MarfaTypeDefinition: Sendable, Equatable {
    public let id: String
    public let parent: String?
    public let fields: [String: MarfaFieldDefinition]
    /// The fields a display hint names, in the order title then body. These
    /// are what offline search matches over.
    public let titleField: String?
    public let bodyField: String?
    /// The version of the schema this definition was generated against.
    public let schemaVersion: Int

    public init(
        id: String,
        parent: String? = nil,
        fields: [String: MarfaFieldDefinition] = [:],
        titleField: String? = nil,
        bodyField: String? = nil,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.parent = parent
        self.fields = fields
        self.titleField = titleField
        self.bodyField = bodyField
        self.schemaVersion = schemaVersion
    }
}

/// Why a set of properties was refused.
///
/// Carries every failure rather than the first, because a person fixing a
/// write wants the whole list — and because the server returns them all, so
/// stopping early would make the local refusal and the remote one disagree
/// about a write neither will accept.
public struct TypeValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    public struct Failure: Equatable, Sendable {
        /// The property, or `_type` when the type itself is unknown.
        public let field: String
        public let message: String

        public init(field: String, message: String) {
            self.field = field
            self.message = message
        }
    }

    public let typeId: String
    public let failures: [Failure]

    public init(typeId: String, failures: [Failure]) {
        self.typeId = typeId
        self.failures = failures
    }

    public var description: String {
        let detail = failures.map { "\($0.field): \($0.message)" }.joined(separator: "; ")
        return "\(typeId) rejected these properties — \(detail)"
    }
}
