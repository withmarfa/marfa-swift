import Foundation

/// What the outbox holds, split by what a person could do about each part.
///
/// **Counts rather than rows.** Rule 19 asks the engine to report itself, and
/// a consumer rendering a status line wants numbers; handing it arrays makes
/// it load every payload to display none of them.
public struct MutationQueueCounts: Sendable, Equatable {

    /// Waiting for the next drain. Ordinary, and clears itself.
    public let pending: Int

    /// Sent, no answer yet. Transient, and included so `pending + inFlight`
    /// is the honest "not yet acknowledged" figure rather than `pending`
    /// alone, which dips as rows leave and reads as progress that has not
    /// happened.
    public let inFlight: Int

    /// Stopped, with a reason, and waiting for the app or the person. This is
    /// the count that means something is wrong.
    ///
    /// **Split by reason rather than totaled, because what clears each one
    /// differs.** A credential a person must replace and a conflict an app
    /// must settle are both stopped, and one number can only say that
    /// something is. An interface that wants the total has ``blockedTotal``.
    public let blocked: [PendingMutationBlockReason: Int]

    /// Refused for good and moved to the dead-letter log. Kept rather than
    /// dropped, so it stays countable until someone dismisses it.
    public let deadLettered: Int

    public init(
        pending: Int,
        inFlight: Int,
        blocked: [PendingMutationBlockReason: Int],
        deadLettered: Int
    ) {
        self.pending = pending
        self.inFlight = inFlight
        self.blocked = blocked
        self.deadLettered = deadLettered
    }

    /// Every stopped mutation, whatever stopped it.
    public var blockedTotal: Int { blocked.values.reduce(0, +) }

    /// Everything not yet acknowledged by the server, however it is faring.
    public var outstanding: Int { pending + inFlight + blockedTotal }

    /// Nothing waiting and nothing stuck. Dead letters are excluded on
    /// purpose: they are finished, and a queue that will never move again is
    /// still a queue with nothing in it.
    public var isSettled: Bool { outstanding == 0 }
}

/// How far a first fill has got, as counts against a total the server gave.
///
/// **The total is asked for rather than inferred.** A page-based import knows
/// how much it has taken and nothing about how much is left, so a progress
/// figure derived from pages is a guess that reaches 90% and stays there. One
/// call to the item-count route before the first page buys a real denominator.
///
/// **What it cannot see, stated here rather than discovered:** the total is a
/// snapshot from before the import began. A space being written to while a
/// device fills can therefore report more imported than the total promised,
/// which is why ``fraction`` clamps and why ``imported`` is the figure to
/// trust. It is progress, not an invariant.
public struct HydrationProgress: Sendable, Equatable {

    /// Rows written so far. Monotonic within one import.
    public let imported: Int

    /// What the server said it held when the import started.
    public let total: Int

    public init(imported: Int, total: Int) {
        self.imported = imported
        self.total = total
    }

    /// `0...1`, clamped.
    ///
    /// **Zero when nothing is known and nothing has arrived**, because a bar
    /// has to render something and "no idea" looks like the start rather than
    /// the end. **One when rows arrived against a total of zero**, which is
    /// the space-grew-during-the-import case at its extreme: the count is the
    /// truth and the fraction cannot express it, so it saturates rather than
    /// dividing by zero.
    public var fraction: Double {
        guard total > 0 else { return imported > 0 ? 1 : 0 }
        return min(1, Double(imported) / Double(total))
    }
}

/// The engine's account of itself: rule 19, in one value.
///
/// Assembled on demand rather than kept live, so it cannot drift from the
/// store it describes.
public struct SyncStatus: Sendable, Equatable {

    /// Whether the engine can currently reach the server.
    public let connection: ConnectionState

    /// The outbox, by disposition.
    public let queue: MutationQueueCounts

    /// When the queue last emptied with nothing refused. `nil` if it never
    /// has — which is different from "a long time ago" and reads that way.
    public let lastCleanDrainAt: Date?

    /// Non-`nil` only while a first fill is running or after one has
    /// finished in this process. An app that shows a bar reads this.
    public let hydration: HydrationProgress?

    public init(
        connection: ConnectionState,
        queue: MutationQueueCounts,
        lastCleanDrainAt: Date?,
        hydration: HydrationProgress?
    ) {
        self.connection = connection
        self.queue = queue
        self.lastCleanDrainAt = lastCleanDrainAt
        self.hydration = hydration
    }
}
