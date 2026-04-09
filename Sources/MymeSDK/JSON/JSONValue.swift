import Foundation

/// A type-erased Codable wrapper for arbitrary JSON values.
///
/// Handles String, Int, Double, Bool, arrays, dictionaries, and null.
/// Used wherever the Myme API sends or receives schemaless property bags.
public enum JSONValue: Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case dictionary([String: JSONValue])
    case null

    // MARK: Convenience Accessors

    /// The underlying `String` if this value is `.string`, otherwise `nil`.
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// The underlying `Int` if this value is `.int`, otherwise `nil`.
    public var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    /// The underlying `Double`. Returns the value for both `.double` and `.int` cases.
    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    /// The underlying `Bool` if this value is `.bool`, otherwise `nil`.
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    /// The underlying array if this value is `.array`, otherwise `nil`.
    public var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    /// The underlying dictionary if this value is `.dictionary`, otherwise `nil`.
    public var dictionaryValue: [String: JSONValue]? {
        if case .dictionary(let v) = self { return v }
        return nil
    }

    /// Whether this value is `.null`.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    // MARK: Conversion — To [String: Any]

    /// Converts this value to an untyped representation.
    public func toAny() -> Any? {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .null: return nil
        case .array(let arr):
            return arr.map { $0.toAny() as Any }
        case .dictionary(let dict):
            var out: [String: Any] = [:]
            for (k, v) in dict {
                if let val = v.toAny() {
                    out[k] = val
                }
            }
            return out
        }
    }

    // MARK: Conversion — From untyped

    /// Creates a `JSONValue` from an untyped value.
    public static func from(_ value: Any) -> JSONValue {
        switch value {
        case let v as String:
            return .string(v)
        case let v as Bool:
            // Bool check before Int/Double because Bool bridges to NSNumber.
            return .bool(v)
        case let v as Int:
            return .int(v)
        case let v as Double:
            return .double(v)
        case let v as [Any]:
            return .array(v.map { from($0) })
        case let v as [String: Any]:
            return .dictionary(v.mapValues { from($0) })
        default:
            return .null
        }
    }

    /// Converts a `[String: Any]` dictionary to `[String: JSONValue]`.
    public static func fromDictionary(_ dict: [String: Any]) -> [String: JSONValue] {
        dict.mapValues { from($0) }
    }

    /// Converts a `[String: JSONValue]` dictionary to `[String: Any]`.
    public static func toDictionary(_ dict: [String: JSONValue]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict {
            if let val = v.toAny() {
                out[k] = val
            }
        }
        return out
    }
}

// MARK: - Codable

extension JSONValue: Codable {

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        // Try types in order: Bool before Int/Double to avoid numeric coercion.
        if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .dictionary(v)
        } else {
            throw Swift.DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSONValue cannot decode value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .dictionary(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - ExpressibleBy Literals

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .dictionary(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}
