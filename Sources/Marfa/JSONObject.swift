/// A JSON object that keeps its keys in order.
///
/// The server answers an item's properties in a defined order, which a
/// document laid out from them follows, so the order is information.
/// Equality and hashing are order-sensitive: two objects with the same pairs
/// in a different order are different.
///
/// Where pairs repeat a key, as in a dictionary literal or the pairs given to
/// ``init(_:)``, the last value wins at the key's first position.
///
/// Swift compares strings by canonical equivalence, so two keys that differ
/// only in Unicode normalization are the same key here.
public struct JSONObject: Sendable, Hashable {
    public private(set) var keys: [String] = []
    public private(set) var values: [JSONValue] = []
    private var positions: [String: Int] = [:]

    public init() {}

    /// The pairs in order; a repeated key keeps its first position and takes
    /// its last value.
    public init(_ pairs: some Sequence<(String, JSONValue)>) {
        for (key, value) in pairs {
            self[key] = value
        }
    }

    /// Reads JSON text that holds one object, keeping its keys in order.
    ///
    /// Refuses, as `MarfaError.decoding`, text that is not strict RFC 8259
    /// JSON, a value that is not an object, a key repeated in one object, and
    /// nesting deeper than ``JSONValue/nestingLimit``.
    public init(json: String) throws {
        self = try JSONReader.object(json)
    }

    /// Compact JSON text with the keys in order.
    ///
    /// Throws `MarfaError.invalid` for a number that is not finite.
    public func json() throws -> String {
        try JSONWriter.text(.object(self))
    }

    public subscript(key: String) -> JSONValue? {
        get { positions[key].map { values[$0] } }
        set {
            guard let newValue else {
                removeValue(forKey: key)
                return
            }
            if let position = positions[key] {
                values[position] = newValue
            } else {
                append(key, newValue)
            }
        }
    }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> JSONValue? {
        guard let position = positions.removeValue(forKey: key) else { return nil }
        keys.remove(at: position)
        for later in keys[position...] {
            positions[later, default: 0] -= 1
        }
        return values.remove(at: position)
    }

    func contains(_ key: String) -> Bool {
        positions[key] != nil
    }

    /// For a key known to be new.
    mutating func append(_ key: String, _ value: JSONValue) {
        positions[key] = keys.count
        keys.append(key)
        values.append(value)
    }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.keys == rhs.keys && lhs.values == rhs.values
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keys)
        hasher.combine(values)
    }
}

extension JSONObject: RandomAccessCollection {
    public typealias Element = (key: String, value: JSONValue)

    public var startIndex: Int { 0 }
    public var endIndex: Int { keys.count }

    public subscript(position: Int) -> Element {
        (keys[position], values[position])
    }
}

extension JSONObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(elements)
    }
}

extension JSONObject: CustomStringConvertible {
    /// JSON text, except that a number that is not finite shows as Swift
    /// writes it.
    public var description: String {
        JSONWriter.description(.object(self))
    }
}

/// Encoding hands the keys to the encoder in order, though an encoder may not
/// keep it: `JSONEncoder` does not, and ``json()`` does. A `Decoder` does not
/// say what order its keys came in, so decoding sorts them; ``init(json:)``
/// keeps the text's order.
extension JSONObject: Codable {
    private struct Name: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Name.self)
        for key in container.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
            self[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Name.self)
        for (key, value) in self {
            try container.encode(value, forKey: Name(stringValue: key))
        }
    }
}
