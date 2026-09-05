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
    /// connectivity failure, a `5xx`, a `429`, a `401` and a suspended space
    /// are statements about the environment rather than about the write, and
    /// each clears without the app doing anything. Counting them would strand a valid write behind an
    /// outage and then need a person to release it — a worse defect than the one
    /// this mechanism exists to fix.
    ///
    /// `CancellationError` is exempt for a less obvious reason.
    /// ``SyncEngine/stop()`` cancels an in-flight replay and the throw lands
    /// here before the loop's `running` check unwinds the cycle, so a row would
    /// accrue one failure per stop. Without this, a handful of ordinary app
    /// backgrounds would block a mutation nothing had ever refused.
    /// Whether a failure is about the environment rather than about the
    /// write: connectivity, a `5xx`, a `429`, a `401`, a suspended space.
    ///
    /// The one definition of that class, so the ceiling and the attempt count
    /// cannot disagree about which failures they are counting.
    static func isEnvironmental(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let marfaError = error as? MarfaError else { return false }
        if marfaError is NetworkError { return true }
        // Guarded on the status for the reason `isPermanent` is: this string
        // could only arrive on a 403 while the parser discarded codes
        // elsewhere, and it no longer does.
        if marfaError.status == 403, marfaError.code == MarfaError.spaceSuspendedCode {
            return true
        }
        switch marfaError.status {
        case 401, 429, 500...599: return true
        default: return false
        }
    }

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
        // The environmental class never blocks, however often it fails, and
        // `isEnvironmental` is the one place that says what is in it — a
        // suspended space is a 403, so it has to be named rather than caught
        // by a status band.
        if isEnvironmental(error) { return nil }

        if let marfaError = error as? MarfaError {
            switch marfaError.status {
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

// MARK: - The prefix a shipped build wrote

/// Reads the `[blocked:<reason>] message` form that `v16.0.0` stored inside
/// `lastError`, before the reason had a column.
///
/// **This is read-only and stays read-only.** Nothing writes the prefix any
/// more; this exists because `v16.0.0` ships schema V2 and its blocked rows
/// are on devices now, and the V2 to V3 migration adds the new column as
/// NULL. Without it an upgrade loses the reason, and loses it in the worst
/// direction: a `resolverMissing` row read as `retriesExhausted` stops
/// auto-replaying when a resolver is registered, which is the recovery
/// `16.0.0` advertised. The raw prefix would also start appearing in front of
/// the error text an app shows a person.
///
/// It can be deleted once no store written by `16.x` can still be opened,
/// which is not a date this file can know.
enum LegacyBlockedPrefix {
    private static let open = "[blocked:"
    private static let close = "] "

    /// The reason a legacy message carries, or `nil` if it carries none.
    static func reason(_ stored: String?) -> PendingMutationBlockReason? {
        guard let stored, stored.hasPrefix(open), let end = stored.range(of: close) else {
            return nil
        }
        let token = String(stored[stored.index(stored.startIndex, offsetBy: open.count)..<end.lowerBound])
        return PendingMutationBlockReason(rawValue: token)
    }

    /// The message without its prefix. A string that never had one is
    /// returned unchanged, which is every string this build writes.
    static func strip(_ stored: String?) -> String? {
        guard let stored, stored.hasPrefix(open), let end = stored.range(of: close) else {
            return stored
        }
        return String(stored[end.upperBound...])
    }
}
