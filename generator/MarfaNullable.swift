// Copied by generator/generate.mjs; edit the template in generator/.

/// A value or an explicit JSON null, distinct from an omitted optional field.
public enum MarfaNullable<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    case value(Value)
    case null

    public var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = container.decodeNil() ? .null : .value(try container.decode(Value.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .value(let value): try container.encode(value)
        }
    }
}

extension KeyedDecodingContainer {
    /// Synthesized decoding normally collapses a missing key and null into nil.
    public func decodeIfPresent<Value>(
        _ type: MarfaNullable<Value>.Type, forKey key: Key
    ) throws -> MarfaNullable<Value>? where Value: Codable & Hashable & Sendable {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }
}
