// Copied by generator/generate.mjs; edit the template in generator/.

/// A JSON null that can be supplied inside an optional generated union.
///
/// Unlike an absent Swift optional, this value writes an explicit null.
public enum MarfaNullValue: Codable, Hashable, Sendable {
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard container.decodeNil() else {
            throw DecodingError.typeMismatch(
                Self.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected JSON null"))
        }
        self = .null
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }
}
