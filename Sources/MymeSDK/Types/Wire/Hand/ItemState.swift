/// The lifecycle state of a Myme item.
///
/// The OpenAPI spec declares `state` as a plain string; the SDK imposes the
/// closed set used by the Myme server: `active`, `archived`, `trashed`,
/// `revoked`. Items begin life as `active`; there is no `new` state. Per-type
/// validation enforces which states a given type can move through —
/// `system.*` items use `active | revoked` only, while `core.*` and other
/// tiered types use the three-state graph (`active | archived | trashed`).
/// If the server ever introduces a new value, decoding a wire payload that
/// carries it will fail loudly — which is the right behaviour.
public enum ItemState: String, Codable, Sendable, Hashable, CaseIterable {
    case active
    case archived
    case trashed
    case revoked
}
