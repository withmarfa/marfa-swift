import Foundation

/// A field definition within a type schema.
///
/// Hand-written because the OpenAPI spec declares `TypeSchema.fields` as an
/// opaque free-form map (`additionalProperties: { nullable: true }`) rather
/// than an explicit shape. The SDK models the field-definition semantics it
/// already understands; if the spec adds structure later, this file can
/// retire.
public struct FieldDefinition: Codable, Sendable {
    public let type: FieldType
    public let description: String?
    public let required: Bool?
    public let enumValues: [String]?
    public let itemsType: String?

    public init(
        type: FieldType,
        description: String? = nil,
        required: Bool? = nil,
        enumValues: [String]? = nil,
        itemsType: String? = nil
    ) {
        self.type = type
        self.description = description
        self.required = required
        self.enumValues = enumValues
        self.itemsType = itemsType
    }

    enum CodingKeys: String, CodingKey {
        case type, description, required
        case enumValues = "enum_values"
        case itemsType = "items_type"
    }
}

/// Supported field types in a type schema.
public enum FieldType: String, Codable, Sendable {
    case string
    case number
    case integer
    case boolean
    case url
    case email
    case datetime
    case date
    case `enum`
    case array
    case object
}
