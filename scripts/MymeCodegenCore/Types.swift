// Foundation-only models for the codegen input shape.
//
// These mirror the subset of the Myme `TypeSchema` wire contract the custom-
// type generator cares about — they intentionally live separately from the
// SDK's wire `TypeSchema` (which stores `fields` as a typeless `JSONValue`
// dictionary) so the generator can stay Foundation-only with no dependency
// on `MymeSDK`.

import Foundation

// MARK: - FieldDefinition

/// One entry inside `TypeSchema.fields`.
public struct CodegenFieldDefinition: Codable, Sendable, Hashable {
    public let type: String
    public let description: String?
    public let format: String?
    public let enumValues: [String]?
    public let itemsType: String?

    public init(
        type: String,
        description: String? = nil,
        format: String? = nil,
        enumValues: [String]? = nil,
        itemsType: String? = nil
    ) {
        self.type = type
        self.description = description
        self.format = format
        self.enumValues = enumValues
        self.itemsType = itemsType
    }

    enum CodingKeys: String, CodingKey {
        case type, description, format
        case enumValues = "enum_values"
        case itemsType = "items_type"
    }
}

// MARK: - DisplayHints

public struct CodegenDisplayHints: Codable, Sendable, Hashable {
    public let titleField: String?
    public let bodyField: String?

    public init(titleField: String? = nil, bodyField: String? = nil) {
        self.titleField = titleField
        self.bodyField = bodyField
    }

    enum CodingKeys: String, CodingKey {
        case titleField = "title_field"
        case bodyField = "body_field"
    }
}

// MARK: - TypeSchema

/// The generator's input contract — one type, one JSON file.
public struct CodegenTypeSchema: Codable, Sendable {
    public let id: String
    public let parent: String?
    public let label: String?
    public let description: String?
    public let version: Int
    public let fields: [String: CodegenFieldDefinition]
    public let required: [String]
    public let displayHints: CodegenDisplayHints?
    public let deferred: Bool?

    public init(
        id: String,
        parent: String? = nil,
        label: String? = nil,
        description: String? = nil,
        version: Int,
        fields: [String: CodegenFieldDefinition],
        required: [String] = [],
        displayHints: CodegenDisplayHints? = nil,
        deferred: Bool? = nil
    ) {
        self.id = id
        self.parent = parent
        self.label = label
        self.description = description
        self.version = version
        self.fields = fields
        self.required = required
        self.displayHints = displayHints
        self.deferred = deferred
    }

    enum CodingKeys: String, CodingKey {
        case id, parent, label, description, version, fields, required
        case displayHints = "display_hints"
        case deferred = "_deferred"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.parent = try c.decodeIfPresent(String.self, forKey: .parent)
        self.label = try c.decodeIfPresent(String.self, forKey: .label)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.version = try c.decode(Int.self, forKey: .version)
        self.fields = try c.decode([String: CodegenFieldDefinition].self, forKey: .fields)
        self.required = (try? c.decode([String].self, forKey: .required)) ?? []
        self.displayHints = try c.decodeIfPresent(CodegenDisplayHints.self, forKey: .displayHints)
        self.deferred = try c.decodeIfPresent(Bool.self, forKey: .deferred)
    }
}
