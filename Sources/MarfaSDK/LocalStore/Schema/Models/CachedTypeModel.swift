// MARK: - Predicate safety
//
// See `Sources/MarfaSDK/LocalStore/Schema/PredicateConventions.swift`.
// Every predicate-relevant column is a stored `String` or `Int`.
// `definitionJson` is opaque to the predicate engine — fetch, then decode
// in Swift.

import Foundation
import SwiftData

/// A type definition as the server last described it, cached on the device.
///
/// The type graph decides whether a write is valid, so a client that can only
/// validate while the server is reachable cannot validate offline at all. This
/// is where the answer lives: whatever `GET /types` last returned, kept so the
/// same rules apply with no network.
///
/// **Nothing writes this table yet.** It is here because the migration that
/// introduced it was happening regardless, and a store that already has the
/// table costs the registry work nothing, while a store that does not costs it
/// a migration of its own — one every device on the previous version has to
/// come through. An empty table on a device that never uses it is the cheaper
/// half of that trade by a wide margin.
///
/// CloudKit-mirrored ready: no `#Unique`, every property defaults, no
/// relationships. Uniqueness on `id` is enforced by the upsert pattern
/// (fetch-by-id, update-or-insert), as it is on every other model here.
@Model
final class CachedTypeModel {
    /// The dotted type identifier — `core.note`, `myapp.invoice`. The logical
    /// key. Dots rather than slashes, matching the wire and the validator.
    var id: String = ""

    /// The parent type this one inherits from, or `nil` at the root of a
    /// chain. Indexed because resolving a type means walking upwards, and the
    /// walk is per validation rather than per session.
    var parent: String?

    /// The type's own schema version, as the server reports it. A cached row
    /// older than the server's is refreshed rather than trusted.
    var schemaVersion: Int = 1

    /// The type definition verbatim, as JSON, exactly as the server returned
    /// it. Stored whole rather than decomposed into columns because the SDK is
    /// not the authority on the shape: a field this build does not know about
    /// survives the round trip and reaches a build that does.
    var definitionJson: String = "{}"

    /// ISO 8601 with fractional seconds — when this row was last written from
    /// a server response. What decides whether a schema refusal gets one
    /// refresh before it is treated as permanent.
    var cachedAt: String = ""

    init() {}

    // MARK: - Indexes

    #Index<CachedTypeModel>([\.id], [\.parent])
}
