import Foundation

/// Strategy for resolving version conflicts during item updates.
///
/// `Codable` so the strategy can be persisted with queued mutations and
/// re-applied during replay. The `.callback` resolver closure itself is
/// not serialisable; on replay, `.callback` degrades to `.auto` because
/// the original resolver function no longer exists in memory.
public enum ConflictStrategy: String, Codable, Sendable {
    /// Auto-merge non-conflicting fields. For conflicting fields, follow
    /// the type's `merge_policy` (server-resolved, embedded in the 409
    /// response): `last_writer_wins` keeps the server's value; `keep_both_copies`
    /// spawns a sibling item tagged `conflicted-copy`. Retries up to 3 times.
    case auto

    /// Throw `ConflictError` immediately, letting the caller handle resolution.
    case manual

    /// Call a custom resolver function. Retries up to 3 times with the resolver's output.
    case callback
}

/// Data provided to a conflict resolver.
public struct ConflictData: Sendable {
    /// The server's current state.
    public let current: ConflictSnapshot

    /// The last common ancestor state.
    public let ancestor: ConflictSnapshot

    /// Fields that differ between the client patch and server state.
    public let conflictingFields: [String]

    /// The properties the client attempted to write.
    public let clientPatch: [String: JSONValue]

    /// The type's resolved merge policy, as emitted by the server in the 409
    /// response. Present in conformant server responses; the SDK falls back
    /// to last-writer-wins per field if absent (legacy / future-proof).
    public let mergePolicy: MergePolicy?
}

/// A function that resolves a version conflict by producing merged properties.
public typealias ConflictResolver = @Sendable (ConflictData) async throws -> [String: JSONValue]

/// Result of a request that may return a 409 conflict.
public enum ConflictResult<T: Sendable>: Sendable {
    case success(T)
    case conflict(ConflictResponse)
}
