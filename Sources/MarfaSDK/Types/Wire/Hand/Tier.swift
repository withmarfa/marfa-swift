/// The intent dimension of an item: `library` (curated, kept, indexed) or
/// `feed` (high-volume, low-intent capture). Items move between tiers
/// through manual or automated curation. Retention windows are operator
/// configuration and live separately from this dimension.
///
/// `tier` is optional on the wire — `system.*` items have no tier, and
/// the SDK models that as `tier == nil`. For `core.*` and other tiered
/// types, the field is always present.
///
/// The OpenAPI spec declares `tier` as a plain string; the SDK imposes
/// the closed set used by the Marfa server. If the server ever introduces
/// a new value, decoding a wire payload that carries it will fail loudly.
public enum Tier: String, Codable, Sendable, Hashable, CaseIterable {
    case library
    case feed
}
