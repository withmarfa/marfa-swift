import Foundation

// MARK: - PendingMutationBlockReason

/// Why a queued mutation cannot proceed until the app changes something.
///
/// A blocked mutation is not a failing one. It has stopped for a reason no
/// number of retries can clear, so the engine stops asking: the drain skips it,
/// it does not mark the cycle failed, and it waits either for the obstacle to
/// go or for ``SyncEngine/retry(id:)``.
public enum PendingMutationBlockReason: String, Sendable, Equatable, CaseIterable, Codable {

    /// The replay needed the resolver an app registers for the `.callback`
    /// conflict strategy and found none. Blocks on the first attempt, because a
    /// second cannot differ.
    ///
    /// The one reason that clears itself: the next drain after
    /// ``MarfaClient/registerConflictResolver(_:)`` replays the mutation with no
    /// further call.
    case resolverMissing

    /// A `409` on an update outlived the conflict loop. The strategy was
    /// `.manual`, or a `.callback` resolver kept returning properties the server
    /// kept refusing, or the update carried a `sourceId` the server already
    /// holds against another row. Only the app can say what should win, so the
    /// mutation waits for it to settle the conflict and call
    /// ``SyncEngine/retry(id:)``.
    case conflictUnresolved

    /// A refusal that is neither permanent nor one of the above failed as often
    /// as the engine is willing to try. Nothing here promises a further attempt
    /// would differ, which is why an unreadable stored reason falls back to it.
    case retriesExhausted
}

// MARK: - Classification

extension PendingMutationBlockReason {

    /// The single place that decides whether a replay failure can be retried.
    ///
    /// `nil` means the next drain should try again. `attemptCount` is the count
    /// *before* this failure, so the ceiling below is compared against the
    /// attempt that has just happened.
    ///
    /// **The network class never blocks, however often it fails.** A
    /// connectivity failure, a `5xx`, a `429` and a `401` are statements about
    /// the environment rather than about the write, and each clears without the
    /// app doing anything. Counting them would strand a valid write behind an
    /// outage and then need a person to release it — a worse defect than the one
    /// this mechanism exists to fix.
    ///
    /// `CancellationError` is exempt for a less obvious reason.
    /// ``SyncEngine/stop()`` cancels an in-flight replay and the throw lands
    /// here before the loop's `running` check unwinds the cycle, so a row would
    /// accrue one failure per stop. Without this, a handful of ordinary app
    /// backgrounds would block a mutation nothing had ever refused.
    static func classify(
        error: Error,
        kind: MutationKind,
        attemptCount: Int,
        ceiling: Int
    ) -> PendingMutationBlockReason? {
        // Keyed by type before status, because status cannot separate these:
        // `ConflictResolverMissingError`, `NetworkError` and
        // `ResponseDecodingError` all carry `status == 0` and mean three
        // different things.
        if error is ConflictResolverMissingError { return .resolverMissing }
        if error is CancellationError { return nil }

        if let marfaError = error as? MarfaError {
            if marfaError is NetworkError { return nil }
            switch marfaError.status {
            case 401, 429, 500...599:
                return nil
            case 409 where kind == .updateItem:
                // Narrowed to the one kind the conflict machinery covers,
                // because the remedy this reason names — resolve the conflict,
                // then `retry(id:)` — is only meaningful there. `updateItem` is
                // the sole caller of the conflict loop, and the unversioned
                // update is where a `source_id` the server holds elsewhere
                // comes back. A 409 the engine can settle itself never reaches
                // here: a create meeting its own id is classed permanent
                // upstream.
                //
                // A 409 on any other kind — a delete, a metadata write — has no
                // conflict to resolve and no strategy to have declined, so
                // telling an app to resolve one would be wrong. Those fall
                // through to the ceiling with every other refusal.
                return .conflictUnresolved
            default:
                break
            }
        }

        // What remains is a refusal that repeating is not expected to fix but
        // that nothing has proven final: a 4xx outside the permanent set, a
        // response the SDK could not decode, a store that refused the write.
        // Try a bounded number of times, then stop.
        return attemptCount + 1 >= ceiling ? .retriesExhausted : nil
    }
}
