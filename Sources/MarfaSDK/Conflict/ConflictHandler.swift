import Foundation

/// Maximum number of conflict resolution retry attempts.
private let maxRetries = 3

/// Tag the **server** applies to the sibling it creates when a
/// `keep_both_copies` field conflicts. Mirrors the `favorite` precedent: a
/// magic tag that lights up app UI. The device no longer creates that sibling
/// and this names the tag for reading, not for writing.
public let conflictedCopyTag = "conflicted-copy"

/// Performs an item update with conflict resolution.
///
/// Mirrors the TypeScript SDK's `handleConflictUpdate` function:
/// loops up to 3 retries, applying the chosen strategy on each 409 conflict.
func handleConflictUpdate(
    transport: any Transport,
    itemId: String,
    clientPatch: [String: JSONValue],
    version: Int,
    strategy: ConflictStrategy,
    resolver: ConflictResolver?,
    tier: Tier? = nil,
    sourceId: String? = nil,
    idempotencyKey: String? = nil
) async throws -> Item {
    let result = try await handleConflictUpdateWithStats(
        transport: transport,
        itemId: itemId,
        clientPatch: clientPatch,
        version: version,
        strategy: strategy,
        resolver: resolver,
        tier: tier,
        sourceId: sourceId,
        idempotencyKey: idempotencyKey
    )
    return result.item
}

/// Returns the resolved item plus a `ConflictAutoMergedPayload` reporting what
/// the server resolved, or `nil` when this write resolved nothing. The
/// summary arrives *with* a success rather than after a retry: the server
/// resolves inside the write's own transaction and says so in the response.
/// Callers that surface a "merged" event (e.g. ``SyncEngine`` for replay-time
/// auto-merges) inspect the payload to decide whether to emit
/// ``SyncEvent/conflictAutoMerged``.
func handleConflictUpdateWithStats(
    transport: any Transport,
    itemId: String,
    clientPatch: [String: JSONValue],
    version: Int,
    strategy: ConflictStrategy,
    resolver: ConflictResolver?,
    tier: Tier? = nil,
    sourceId: String? = nil,
    idempotencyKey: String? = nil
) async throws -> (item: Item, mergeSummary: ConflictAutoMergedPayload?) {
    var properties = clientPatch
    var currentVersion = version

    // **Set when the previous attempt was refused for a thinned ancestor**,
    // which is the one retry whose body is a function of the row and the
    // server's version rather than of a resolver's judgement — so it is the
    // one retry that can still be named by a key.
    var rebasedOntoServerVersion = false

    for attempt in 0...maxRetries {
        let body = UpdateItemBody(
            properties: properties,
            version: currentVersion,
            tier: tier,
            sourceId: sourceId
        )

        // **`conflict=auto` hands resolution to the server**, which does it
        // inside this write's own transaction by the type's merge policy. The
        // device used to do it here, and two implementations of one rule is
        // what moving it into the server was meant to end — the Swift kit's
        // `last_writer_wins` even ran the *other way*, keeping the earlier
        // write where the server keeps the later one, so two devices editing
        // one field reached different answers depending only on which kit
        // resolved it. The device also spawned its own `keep_both_copies`
        // sibling through an unkeyed create, so a lost response made two.
        //
        // `manual` and `callback` deliberately send nothing: both mean the
        // caller resolves, and the server's default for an omitted parameter
        // is `manual`, so silence says exactly what they mean.
        let query: [(String, String)]? = (strategy == .auto) ? [("conflict", "auto")] : nil

        // **Every attempt is keyed, and attempt zero's key is the row's.** A
        // lost response on attempt zero leaves the caller
        // believing nothing landed; it replays, the server has already moved
        // the version, and the write comes back as a conflict *over the edit
        // that landed* — the caller is told it collided when it succeeded.
        // A key turns that into the replayed original.
        //
        // A later attempt is either a rebase onto the version the server said
        // it holds, whose body this code can name, or a resolver's answer,
        // whose body it cannot — `keyForAttempt` draws that line. Under
        // `.auto` the rebase is the only way to reach one at all, because the
        // server resolves an ordinary conflict in its own transaction and this
        // loop does not retry that.
        let result: ConflictResult<ItemResponse>
        do {
            result = try await transport.requestWithConflict(
                method: .patch,
                path: "/items/\(itemId.escapedPathSegment)",
                body: body,
                query: query,
                idempotencyKey: keyForAttempt(
                attempt: attempt,
                rowKey: idempotencyKey,
                rebased: rebasedOntoServerVersion,
                version: currentVersion
            )
            )
        } catch let thinned as AncestorUnavailableError {
            // **The write named a version history no longer retains, and the
            // server said which version it does hold.** That is enough to
            // rebase on, and rebasing is the whole reason the error carries
            // `current` — without it the row parks as an unresolved conflict
            // whose stated remedy, `retry(id:)`, re-sends the same stale
            // version and fails identically for as long as anyone retries.
            //
            // Only under `.auto`, and only while attempts remain. `manual` and
            // `callback` mean the caller resolves, and rebasing under them
            // would apply an edit onto a base the caller never saw, which is
            // exactly the decision those strategies exist to keep. Under
            // `.auto` applying this write on top of the server's current state
            // is what `last_writer_wins` already means.
            guard strategy == .auto, attempt < maxRetries else { throw thinned }
            currentVersion = thinned.current.version
            rebasedOntoServerVersion = true
            continue
        }

        switch result {
        case .success(let response):
            // **The server says what it did; the kit no longer infers it.**
            // `conflict_resolution` is present only on a write that resolved
            // a conflict, and it is the only place a spawned sibling's id is
            // ever reported — no route says what a write created. A
            // `.callback` resolution carries none, because the caller
            // resolved and the server merely accepted an ordinary write.
            let summary = response.conflictResolution.map { resolution in
                ConflictAutoMergedPayload(
                    itemId: itemId,
                    mergedItemId: response.item.id,
                    conflictedCopyId: resolution.conflictedCopyId,
                    fields: resolution.fields.sorted(),
                    strategy: resolution.strategy
                )
            }
            return (item: response.item, mergeSummary: summary)

        case .conflict(let conflictResponse):
            // Manual strategy: always throw immediately
            if case .manual = strategy {
                throw ConflictError(
                    current: conflictResponse.current,
                    ancestor: conflictResponse.ancestor,
                    conflictingFields: conflictResponse.conflictingFields,
                    clientPatch: clientPatch
                )
            }

            // Max retries exhausted
            if attempt == maxRetries {
                throw ConflictError(
                    current: conflictResponse.current,
                    ancestor: conflictResponse.ancestor,
                    conflictingFields: conflictResponse.conflictingFields,
                    clientPatch: clientPatch
                )
            }

            let conflict = ConflictData(
                itemId: itemId,
                current: conflictResponse.current,
                ancestor: conflictResponse.ancestor,
                conflictingFields: conflictResponse.conflictingFields,
                clientPatch: clientPatch,
                mergePolicy: conflictResponse.mergePolicy
            )

            switch strategy {
            case .auto:
                // **A `409` under `conflict=auto` is not one the server
                // declined to resolve — it is one it could not.** A thinned
                // ancestor reaches the caller as `AncestorUnavailableError`
                // from the transport before this point, so what is left here
                // is a refusal about the request rather than a race. Merging
                // it on the device would put the second implementation back.
                throw ConflictError(
                    current: conflictResponse.current,
                    ancestor: conflictResponse.ancestor,
                    conflictingFields: conflictResponse.conflictingFields,
                    clientPatch: clientPatch
                )
            case .callback:
                guard let resolver else {
                    throw ConflictError(
                        current: conflict.current,
                        ancestor: conflict.ancestor,
                        conflictingFields: conflict.conflictingFields,
                        clientPatch: clientPatch
                    )
                }
                properties = try await resolver(conflict)
            case .manual:
                break // Already handled above
            }

            currentVersion = conflictResponse.current.version
        }
    }

    // Should not be reachable
    throw MarfaError(code: "conflict_exhausted", message: "Conflict resolution exhausted", status: 409)
}

/// Which key, if any, an attempt may carry.
///
/// **The first attempt takes the row's key**, because it is the attempt whose
/// lost response leaves a caller believing nothing landed while the server has
/// already moved the version.
///
/// **A rebased retry takes a key naming the version it rebases onto.** Its
/// body is a function of the row and that version, so the same situation
/// always produces the same key and a different one always produces a
/// different key — which is what the server requires, since it refuses a key
/// replayed with a different request. Without this a lost response on the
/// retry replays the whole row and applies the patch twice.
///
/// **A resolver's retry takes a freshly minted one.** Nothing here can
/// *derive* a key for it — a resolver returns whatever it likes, so the same
/// derivation could name two different bodies, which the server refuses. But a
/// minted key names this request exactly, is never reused with a different
/// body, and is strictly better than sending none: it survives the transport's
/// own retry of this attempt, which is the window where a `.timedOut` replays
/// a write the server may already have committed. What it cannot do is dedupe
/// across drains, and neither could `nil`.
///
/// **The `-v` derivation's stability across drains rests on a server
/// property, not on anything in this file.** The server records the outcome of
/// a keyed write — *including a conflict* — and answers a repeat of that key
/// with the stored result. So a replayed attempt zero is told the same
/// `current.version` it was told the first time, and the retry re-derives the
/// same key. Were the refusal not recorded, attempt zero would re-execute,
/// name a newer version, and the retry would mint a fresh key every drain.
func keyForAttempt(
    attempt: Int,
    rowKey: String?,
    rebased: Bool,
    version: Int
) -> String? {
    // Attempt zero replays under the row's key or, for a row enqueued before
    // that column existed, under none — replaying exactly as it always did.
    if attempt == 0 { return rowKey }
    // A later attempt can always be keyed. A minted key changes nothing across
    // drains, which is the only thing the legacy row's behaviour is about, so
    // withholding one from it would protect nothing and leave a write on a
    // keyed route unkeyed.
    guard let rowKey, rebased else { return UUIDv7.generateString() }
    return "\(rowKey)-v\(version)"
}
