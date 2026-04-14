/// The lifecycle state of a Myme item.
///
/// The OpenAPI spec declares `state` as a plain string; the SDK imposes the
/// closed set used by the Myme server (new, active, archived, trashed).
/// If the server ever introduces a new state, decoding a wire payload that
/// carries it will fail loudly — which is the right behaviour.
public enum ItemState: String, Codable, Sendable, Hashable, CaseIterable {
    case new
    case active
    case archived
    case trashed
}
