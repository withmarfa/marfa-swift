extension JSONObject {
    /// A key by its bytes, as the core and the server tell keys apart: two
    /// that differ only in Unicode normalization, which Swift compares as
    /// equal strings, are two keys.
    struct Name: Hashable, Sendable {
        let bytes: [UInt8]

        init(_ key: String) {
            bytes = Array(key.utf8)
        }
    }

    /// The pairs in order; a repeated key keeps its first position and takes
    /// its last value.
    public init(_ pairs: some Sequence<(String, JSONValue)>) {
        self.init()
        var positions: [Name: Int] = [:]
        for (key, value) in pairs {
            if let position = positions[Name(key)] {
                members[position].value = value
            } else {
                positions[Name(key)] = members.count
                members.append(JSONMember(key: key, value: value))
            }
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

    public var keys: [String] { members.map(\.key) }

    public var values: [JSONValue] { members.map(\.value) }

    /// Looks a key up by its bytes, scanning the keys in order.
    ///
    /// Setting a key that is there replaces its value in place, a new key goes
    /// last, and `nil` removes it.
    public subscript(key: String) -> JSONValue? {
        get { position(of: key).map { members[$0].value } }
        set {
            guard let newValue else {
                removeValue(forKey: key)
                return
            }
            if let position = position(of: key) {
                members[position].value = newValue
            } else {
                members.append(JSONMember(key: key, value: newValue))
            }
        }
    }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> JSONValue? {
        guard let position = position(of: key) else { return nil }
        return members.remove(at: position).value
    }

    private func position(of key: String) -> Int? {
        members.firstIndex { $0.key.utf8.elementsEqual(key.utf8) }
    }
}

extension JSONObject: RandomAccessCollection {
    public typealias Element = (key: String, value: JSONValue)

    public var startIndex: Int { 0 }
    public var endIndex: Int { members.count }

    public subscript(position: Int) -> Element {
        (members[position].key, members[position].value)
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
    private struct CodingName: CodingKey {
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
        let container = try decoder.container(keyedBy: CodingName.self)
        let keys = container.allKeys.sorted(by: { $0.stringValue < $1.stringValue })
        self.init(try keys.map { ($0.stringValue, try container.decode(JSONValue.self, forKey: $0)) })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingName.self)
        for (key, value) in self {
            try container.encode(value, forKey: CodingName(stringValue: key))
        }
    }
}
