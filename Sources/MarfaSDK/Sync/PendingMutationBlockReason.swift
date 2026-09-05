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
    ///
    /// **One cause does not fit that remedy, and an app should expect it.** A
    /// write refused because history no longer retains the version it names
    /// arrives here under `.manual` and `.callback` — and `retry(id:)` re-sends
    /// that same version, so it is refused identically however often anyone
    /// retries. The row's error is an ``AncestorUnavailableError`` carrying the
    /// version the server does hold; settling it means writing against that
    /// version rather than retrying this row.
    ///
    /// **`.auto` reaches this state too, and routinely.** A `409` the server
    /// could not resolve surfaces as a `ConflictError` and parks here, which
    /// is the ordinary outcome for an `.auto` write the server declined — an
    /// app that handles no `.auto` case is mishandling the likeliest one. What
    /// `.auto` does not do is park on a *first* thinned ancestor: the loop
    /// rebases and goes again, and only reaches here once that budget is
    /// spent.
    ///
    /// **And under `.auto` and `.manual`, `retry(id:)` does not reach the
    /// server at all.** The row's idempotency key is minted once and its body
    /// re-encodes identically, and the server retains a `409` against a key
    /// rather than releasing it — so the repeat is answered from its record
    /// and the same refusal comes back. `.callback` escapes that, because the
    /// resolver's answer goes out under a fresh key; it can still park here if
    /// the resolver's answers keep being refused. Where retrying cannot help,
    /// ``SyncEngine/discard(id:)`` is what releases the row and the item
    /// behind it.
    case conflictUnresolved

    /// A refusal that is neither permanent nor one of the above failed as often
    /// as the engine is willing to try. Nothing here promises a further attempt
    /// would differ, which is why an unreadable stored reason falls back to it.
    case retriesExhausted

    /// The server refused the credential, and the transport had already spent
    /// its one refresh on it. Every queued write parks together, because they
    /// all carry the same credential and none of them can succeed until a
    /// person replaces it.
    ///
    /// **This is the one refusal that looks environmental and is not.** A
    /// connectivity failure, a `5xx` and a `429` all clear on their own; a
    /// spent credential clears only when somebody signs in again. Treated as
    /// environmental, as it was, the queue retried for ever and an app could
    /// show only a count of unsent writes that never moved — with nothing
    /// anywhere saying what the person had to do.
    case credentialRefused

    /// The idempotency key on this write has already been answered for a
    /// different body, so the server refuses it with `idempotency_key_reused`.
    ///
    /// **Parks on the first refusal, because the key is spent rather than the
    /// write.** Repeating it is refused identically however often anyone tries,
    /// so the retry ceiling would be spent on guaranteed refusals and the row
    /// would then park under a reason naming the wrong cause.
    ///
    /// **What clears it is ``SyncEngine/discard(id:)``.** `retry(id:)` re-sends
    /// the spent key. Re-applying the edit — which this comment recommended
    /// until the discard door existed — does not route around it either: the fresh mutation is a
    /// new row under the same local id, queued after the blocked one, and the
    /// replay defers every later write to an item behind that item's blocked
    /// row. So it waits behind the row it was meant to replace, and the item
    /// takes no further writes until something removes it.
    case idempotencyKeyReused
}

// MARK: - Classification

extension PendingMutationBlockReason {

    /// The single place that decides whether a replay failure can be retried.
    ///
    /// `nil` means the next drain should try again. `refusalCount` is the
    /// count *before* this failure, so the ceiling below is compared against
    /// the refusal that has just happened.
    ///
    /// **The environmental class never blocks, however often it fails.** A
    /// connectivity failure, a `5xx`, a `429` and a suspended space are
    /// statements about the environment rather than about the write, and each
    /// clears without the app doing anything. Counting them would strand a
    /// valid write behind an outage and then need a person to release it — a
    /// worse defect than the one this mechanism exists to fix.
    ///
    /// **A `401` was in that list and is not any more.** It clears only when a
    /// person replaces the credential, so retrying it for ever left an app with
    /// nothing to say beyond an unsent count that did not move. It is
    /// classified above this, as
    /// ``PendingMutationBlockReason/credentialRefused``.
    ///
    /// `CancellationError` is exempt for a less obvious reason.
    /// ``SyncEngine/stop()`` cancels an in-flight replay and the throw lands
    /// here before the loop's `running` check unwinds the cycle, so a row would
    /// accrue one failure per stop. Without this, a handful of ordinary app
    /// backgrounds would block a mutation nothing had ever refused.
    /// Whether a failure is about the environment rather than about the
    /// write: connectivity, a `5xx`, a `429`, a suspended space — and a `401`,
    /// which is the one entry that is true of this function and no longer true
    /// of the kit. `classify` returns `credentialRefused` before ever asking,
    /// so this answer is never the one that decides a 401. It stays because it
    /// remains a true statement about the transport class, and because a
    /// reordering that put this first would otherwise start counting a dead
    /// credential toward the ceiling in silence.
    ///
    /// The one definition of that class, so nothing that consults it can
    /// disagree about which failures it means. It is transport-shaped: see
    /// ``isServerRefusal(_:)`` for what the ceiling counts, which excludes a
    /// class this cannot see.
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

    /// Whether the server refused this write, which is what the retry ceiling
    /// counts.
    ///
    /// **Narrower than "not environmental", and the difference is a class the
    /// transport never sees.** A replay writes to the local store *after* a
    /// `2xx` — it adopts the row the server returned — so a store that refuses
    /// there is a write the server accepted. That is not a refusal, and a
    /// store failing for its own environmental reason (a locked device, a full
    /// disk) would otherwise spend the whole budget on an answer that was yes.
    static func isServerRefusal(_ error: Error) -> Bool {
        guard error is MarfaError else { return false }
        return !isEnvironmental(error)
    }

    static func classify(
        error: Error,
        kind: MutationKind,
        refusalCount: Int,
        ceiling: Int
    ) -> PendingMutationBlockReason? {
        // Keyed by type before status, because status cannot separate these:
        // `ConflictResolverMissingError`, `NetworkError` and
        // `ResponseDecodingError` all carry `status == 0` and mean three
        // different things.
        if error is ConflictResolverMissingError { return .resolverMissing }

        // **Before the environmental sweep, which used to swallow this.** A
        // `401` reaching the queue is one the transport's single refresh did
        // not clear, so it is a statement about the credential rather than
        // about the network — and unlike everything else in that class it does
        // not clear on its own.
        //
        // `isEnvironmental` still answers `true` for a 401 and is never asked:
        // this returns first, so the `case 401` below is unreachable from
        // here. It is left in place because it remains a true statement about
        // the transport class, and because a future reordering that put the
        // sweep first would otherwise start counting a dead credential toward
        // the ceiling silently.
        //
        // **What keeps this off the ceiling is `recordBlocked`**, which does
        // not raise `refusalCount` — not the sweep. That distinction matters:
        // a reader who believes the sweep is load-bearing here will preserve
        // the wrong thing.
        if let marfaError = error as? MarfaError, marfaError.status == 401 {
            return .credentialRefused
        }

        // A key answered for a different body cannot be replayed into a
        // different answer, so this parks rather than spending the ceiling on
        // refusals that are all the same refusal.
        if let marfaError = error as? MarfaError,
            marfaError.status == 422,
            // 422 confirmed against the server's own code-to-status map
            // in `packages/shared/src/errors.ts`, not inferred from the kit.
            marfaError.code == MarfaError.idempotencyKeyReusedCode
        {
            return .idempotencyKeyReused
        }

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
        // **Refusals, not attempts.** The two coincided until a device could
        // stay offline for a week; counting an attempt nobody could make
        // conflates "we could not ask" with "we asked and were refused".
        return refusalCount + 1 >= ceiling ? .retriesExhausted : nil
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
