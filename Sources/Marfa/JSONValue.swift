public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    /// Kept exact, where a `Double` holds integers exactly only up to 2^53.
    /// `1.0` and `1e2` read as integers; an integer beyond `Int64` reads as an
    /// inexact `number`.
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    /// The deepest nesting of arrays and objects that ``init(json:)`` and
    /// ``JSONObject/init(json:)`` read.
    public static let nestingLimit = 512

    /// Reads strict RFC 8259 JSON text, keeping each object's keys in order.
    ///
    /// Refuses, as `MarfaError.decoding`, anything else: comments, trailing
    /// commas, a number JSON does not allow or a `Double` cannot hold, an
    /// unescaped control character, a lone surrogate, invalid UTF-8, a key
    /// repeated in one object, and nesting deeper than ``nestingLimit``.
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
        self = .object(JSONObject(elements))
    }
}

