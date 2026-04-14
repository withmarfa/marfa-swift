/// Origin of an item or credential action: human (user), agent (ai), or
/// background process (worker). Matches the V0 three-value set.
///
/// Declared on the wire as a plain `string` in most responses; the SDK
/// imposes the closed set so consumers get compile-time safety. If the
/// server ever introduces a new origin, decoding will fail loudly.
public enum Origin: String, Codable, Sendable, Hashable, CaseIterable {
    case user
    case ai
    case worker
}
