import Foundation

/// A JSON value: an item's properties and an extension's body are made of
/// these, whole values rather than anything the package interprets.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    /// A number whose value is an integer `Int64` holds, kept exact: a
    /// `Double` holds integers exactly only up to 2^53. `1.0` and `1e2` read
    /// as integers; an integer beyond `Int64` reads as an inexact `number`.
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    /// Either kind of number, as a `Double`.
    public var number: Double? {
        switch self {
        case .number(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }

    public var integer: Int64? {
        if case .integer(let value) = self { value } else { nil }
    }

    public var bool: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// The text of an object of properties, as the core takes it, and back.
enum Properties {
    static func text(_ properties: [String: JSONValue]) throws -> String {
        String(decoding: try JSONEncoder().encode(properties), as: UTF8.self)
    }

    static func object(_ text: String) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8))
    }
}
