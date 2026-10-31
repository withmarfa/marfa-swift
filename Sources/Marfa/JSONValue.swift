package import MarfaCore

/// One JSON value.
///
/// An integer is kept exact, where a `Double` holds integers exactly only up to 2^53; an integer beyond `Int64`
/// arrives as the nearest `number`.
///
/// Marfa holds a number as a 64-bit float, so a write refuses, as
/// `MarfaError.validation` with the code `invalid_properties`, an integer
/// with 16 or more digits that it would serve back with other digits, such as
/// `9007199254740993`. Send such a number as a string.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    package init(_ core: MarfaCore.JsonValue) {
        switch core {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .integer(let value): self = .integer(value)
        case .number(let value): self = .number(value)
        case .string(let value): self = .string(value)
        case .array(let values): self = .array(values.map(JSONValue.init))
        case .object(let object): self = .object(JSONObject(object))
        }
    }

    package var core: MarfaCore.JsonValue {
        switch self {
        case .null: .null
        case .bool(let value): .bool(value)
        case .integer(let value): .integer(value)
        case .number(let value): .number(value)
        case .string(let value): .string(value)
        case .array(let values): .array(values.map(\.core))
        case .object(let object): .object(object.core)
        }
    }
}

/// One key of a ``JSONObject`` and its value.
public struct JSONMember: Sendable, Hashable {
    public var key: String
    public var value: JSONValue

    public init(key: String, value: JSONValue) {
        self.key = key
        self.value = value
    }

    package init(_ core: MarfaCore.JsonMember) {
        key = core.key
        value = JSONValue(core.value)
    }

    package var core: MarfaCore.JsonMember { MarfaCore.JsonMember(key: key, value: value.core) }
}

/// A JSON object that keeps its keys in order.
///
/// The server answers an item's properties in a defined order, which a
/// document laid out from them follows, so the order is information.
/// Equality and hashing are order-sensitive: two objects with the same pairs
/// in a different order are different. They compare keys as Swift compares
/// strings, so two keys that differ only in Unicode normalization compare
/// equal, though a lookup tells them apart by their UTF-8 bytes, as the core
/// and the server do.
public struct JSONObject: Sendable, Hashable {
    public var members: [JSONMember]

    public init(members: [JSONMember] = []) {
        self.members = members
    }

    package init(_ core: MarfaCore.JsonObject) {
        members = core.members.map(JSONMember.init)
    }

    package var core: MarfaCore.JsonObject { MarfaCore.JsonObject(members: members.map(\.core)) }
}

extension JSONValue {
    /// The deepest nesting of arrays and objects that ``init(json:)`` and
    /// ``JSONObject/init(json:)`` read.
    public static let nestingLimit = 512

    /// Reads strict RFC 8259 JSON text, keeping each object's keys in order.
    ///
    /// Refuses, as `MarfaError.decoding`, anything else: comments, trailing
    /// commas, a number JSON does not allow or a `Double` cannot hold, an
    /// unescaped control character, a lone surrogate, invalid UTF-8, a key
    /// repeated in one object, and nesting deeper than ``nestingLimit``. An
    /// integer that `Int64` holds reads exact, whatever form the text gives
    /// it, so `1.0` and `1e2` are integers.
    public init(json: String) throws {
        self = try JSONReader.value(json)
    }

    /// Compact JSON text with each object's keys in order.
    ///
    /// Throws `MarfaError.invalid` for a number that is not finite.
    public func json() throws -> String {
        try JSONWriter.text(self)
    }

    public var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    /// Either kind of number.
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

    public var array: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    public var object: JSONObject? {
        if case .object(let value) = self { value } else { nil }
    }
}

extension JSONValue: CustomStringConvertible {
    /// JSON text, except that a number that is not finite shows as Swift
    /// writes it.
    public var description: String {
        JSONWriter.description(self)
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
            self = .object(try container.decode(JSONObject.self))
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

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(JSONObject(elements))
    }
}
