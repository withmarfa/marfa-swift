import Foundation

/// Strategy for resolving version conflicts during item updates.
///
/// `Codable` so the strategy can be persisted with queued mutations and
/// re-applied during replay.
///
/// The `.callback` resolver closure itself is not serializable, and a
/// replay therefore cannot reach the closure a call site passed. It does
/// **not** fall back to `.auto`: resolving under a strategy the caller did
/// not choose is the thing this avoids. A replayed `.callback` update runs
/// the resolver registered on the client with
/// ``MarfaClient/registerConflictResolver(_:)``, and if none is registered
/// it throws ``ConflictResolverMissingError`` and stays queued until one is.
///
/// Register one at startup on any synced client that uses `.callback`.
/// Passing `resolve:` per call is accepted and is not sufficient on its own:
/// on a synced client the write lands locally and is queued, so the closure
/// is never what resolves the collision. The replay is.
public enum ConflictStrategy: String, Codable, Sendable {
    /// **Ask the server to resolve**, which it does inside this write's own
    /// transaction by the type's `merge_policy`: a `last_writer_wins` field
    /// takes this write's value, and a `keep_both_copies` field leaves the
    /// server's value on the item while the losing value lands on a sibling
    /// tagged ``conflictedCopyTag``. What it did comes back on the response
    /// and reaches an app as ``SyncEvent/conflictAutoMerged``.
    ///
    /// **The device does not merge and does not retry a conflict.** A `409`
    /// that comes back anyway is one the server could not resolve rather than
    /// one it declined, and it is thrown. The one thing retried here is a
    /// write refused because history no longer retains the version it named:
    /// that rebases onto the version the server does hold and goes again.
    case auto

    /// Throw `ConflictError` immediately, letting the caller handle resolution.
    case manual

    /// Call a custom resolver function. Retries up to 3 times with the resolver's output.
    case callback
}

/// Data provided to a conflict resolver.
public struct ConflictData: Sendable {
    /// The item being resolved.
    ///
    /// A per-call resolver already knows this, because the call site just
    /// passed the id. A registered one does not, and a registered one is the
    /// only kind a replayed `.callback` update can reach. Without it such a
    /// resolver can merge but cannot report, so an app has nothing to name in
    /// a message to a person.
    public let itemId: String

    /// The server's current state.
    public let current: ConflictSnapshot

    /// The last common ancestor state.
    public let ancestor: ConflictSnapshot

    /// Fields that differ between the client patch and server state.
    public let conflictingFields: [String]

    /// The properties the client attempted to write.
    public let clientPatch: [String: JSONValue]

    /// The type's resolved merge policy, as emitted by the server in the 409
    /// response, for a caller resolving it by hand. Nothing in the kit reads
    /// it any more: `.auto` is resolved by the server, and `.manual` and
    /// `.callback` hand the whole envelope to the caller.
    public let mergePolicy: MergePolicy?

    /// The SDK builds these; an app only reads them. Exposed to test support
    /// so a consumer can exercise the resolver it registers without standing
    /// up a server that will conflict on demand — which is otherwise the only
    /// way to obtain one, and so the reason a registered resolver goes
    /// untested. Not public: an app that constructed one would be pinned by
    /// every field added here.
    @_spi(MarfaSDKTestSupport)
    public init(
        itemId: String,
        current: ConflictSnapshot,
        ancestor: ConflictSnapshot,
        conflictingFields: [String],
        clientPatch: [String: JSONValue],
        mergePolicy: MergePolicy?
    ) {
        self.itemId = itemId
        self.current = current
        self.ancestor = ancestor
        self.conflictingFields = conflictingFields
        self.clientPatch = clientPatch
        self.mergePolicy = mergePolicy
    }
}

/// A function that resolves a version conflict by producing merged properties.
public typealias ConflictResolver = @Sendable (ConflictData) async throws -> [String: JSONValue]

/// Result of a request that may return a 409 conflict.
public enum ConflictResult<T: Sendable>: Sendable {
    case success(T)
    case conflict(ConflictResponse)
}
