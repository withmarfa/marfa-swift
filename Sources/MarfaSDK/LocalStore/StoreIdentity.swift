import Foundation

/// Which axis of a store's identity disagreed with the client opening it.
public enum StoreIdentityAxis: String, Sendable, Equatable {
    /// The server the store's contents came from.
    case origin
}

/// A store opened by a client it does not belong to.
///
/// **This refuses rather than reconciling, and there is nothing to reconcile.**
/// A store holds one server's rows, one event cursor and a queue of writes
/// addressed to that server. Opening it against a different origin does not
/// produce a store with two servers' data in it — it produces one where every
/// later answer overwrites rows that were never the same rows, and a queue
/// that replays somebody's edits at a server that has never heard of them.
/// The failure is silent and there is no later signal that distinguishes it
/// from ordinary drift.
public final class StoreIdentityMismatchError: MarfaError {
    /// Which axis disagreed. Named rather than described, because the
    /// remedies differ and a caller has to tell them apart.
    public let axis: StoreIdentityAxis

    /// What the store recorded.
    public let recorded: String

    /// What the client opening it carries.
    public let found: String

    public init(axis: StoreIdentityAxis, recorded: String, found: String) {
        self.axis = axis
        self.recorded = recorded
        self.found = found
        super.init(
            code: "store_identity_mismatch",
            message: """
                This store belongs to a different \(axis.rawValue): it recorded \
                \(recorded) and this client carries \(found). Opening it anyway \
                would overwrite rows that are not the same rows and replay \
                queued writes at a server that has never seen them. Use a \
                separate store path per \(axis.rawValue).
                """,
            status: 0
        )
    }

    /// Permanent by construction: nothing about a later attempt differs.
    public override var isPermanent: Bool { true }
}
