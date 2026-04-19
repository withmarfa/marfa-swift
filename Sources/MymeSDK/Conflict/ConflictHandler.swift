import Foundation

/// Maximum number of conflict resolution retry attempts.
private let maxRetries = 3

/// Tag applied to a sibling item spawned by the keep-both flow on conflict.
/// Mirrors the `favorite` precedent: a magic tag that lights up app UI.
public let conflictedCopyTag = "conflicted-copy"

// MARK: - Resolution result

/// Outcome of a single auto-merge resolution decision.
///
/// `mergedProperties` is what should be PATCHed back as the original item's
/// next state (server values for keep-both fields, client values for
/// non-conflicting fields, plus whatever non-keep-both client overrides
/// the policy permits — which today is "none, server wins").
///
/// `conflictedCopyId` is non-nil only when the keep-both flow ran and a
/// sibling item was created.
///
/// `appliedStrategies` records the per-field strategy that fired, keyed by
/// JSON field name. Used by the SyncEngine to enrich the
/// `conflictAutoMerged` event payload.
struct ConflictResolutionOutcome: Sendable {
    var mergedProperties: [String: JSONValue]
    var conflictedCopyId: String?
    var appliedStrategies: [String: MergePolicyStrategy]
}

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
    library: Bool? = nil
) async throws -> Item {
    let result = try await handleConflictUpdateWithStats(
        transport: transport,
        itemId: itemId,
        clientPatch: clientPatch,
        version: version,
        strategy: strategy,
        resolver: resolver,
        library: library
    )
    return result.item
}

/// Returns the resolved item plus a `ConflictAutoMergedPayload` summarising
/// the auto-merges that fired (or `nil` when the first attempt succeeded).
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
    library: Bool? = nil
) async throws -> (item: Item, mergeSummary: ConflictAutoMergedPayload?) {
    var properties = clientPatch
    var currentVersion = version

    // Aggregated across retries — each 409 contributes its conflicting fields
    // and applied strategies. The conflicted-copy id (if any) is set once;
    // the keep-both flow runs at most one sibling spawn per resolution cycle
    // because subsequent retries replay against post-merge server state with
    // no client-side claim on the keep-both fields.
    var aggregatedFields = Set<String>()
    var aggregatedStrategies: [String: MergePolicyStrategy] = [:]
    var conflictedCopyId: String?

    for attempt in 0...maxRetries {
        let body = UpdateItemBody(
            properties: properties,
            version: currentVersion,
            library: library
        )

        let result: ConflictResult<ItemResponse> = try await transport.requestWithConflict(
            method: .patch,
            path: "/items/\(itemId)",
            body: body,
            query: nil
        )

        switch result {
        case .success(let response):
            let summary: ConflictAutoMergedPayload? = aggregatedFields.isEmpty
                ? nil
                : ConflictAutoMergedPayload(
                    itemId: itemId,
                    mergedItemId: response.item.id,
                    conflictedCopyId: conflictedCopyId,
                    fields: aggregatedFields.sorted(),
                    strategy: aggregatedStrategies
                )
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
                current: conflictResponse.current,
                ancestor: conflictResponse.ancestor,
                conflictingFields: conflictResponse.conflictingFields,
                clientPatch: clientPatch,
                mergePolicy: conflictResponse.mergePolicy
            )

            switch strategy {
            case .auto:
                let outcome = try await autoMergeWithPolicy(
                    transport: transport,
                    itemId: itemId,
                    conflict: conflict
                )
                properties = outcome.mergedProperties
                aggregatedFields.formUnion(conflict.conflictingFields)
                for (field, applied) in outcome.appliedStrategies {
                    aggregatedStrategies[field] = applied
                }
                if let spawned = outcome.conflictedCopyId {
                    // Only one sibling spawn per cycle. Subsequent 409s on
                    // the same retry chain reflect post-merge state.
                    conflictedCopyId = conflictedCopyId ?? spawned
                }
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
    throw MymeError(code: "conflict_exhausted", message: "Conflict resolution exhausted", status: 409)
}

// MARK: - Policy-aware auto-merge

/// Apply per-field merge policy from the conflict response. For any
/// conflicting field with `keep_both_copies`, spawn a sibling item via
/// ``keepBothFlow``; the original item retains the server's value (no
/// client claim survives in the merged patch). For `last_writer_wins` (or
/// missing/legacy policy) the server's value wins on conflict and the
/// client wins on non-conflicting fields — the v2.x behaviour, now explicit.
func autoMergeWithPolicy(
    transport: any Transport,
    itemId: String,
    conflict: ConflictData
) async throws -> ConflictResolutionOutcome {
    // Classify each conflicting field by the policy that applies to it.
    var keepBothFields: [String] = []
    var lastWriterWinsFields: [String] = []
    var applied: [String: MergePolicyStrategy] = [:]

    for field in conflict.conflictingFields {
        let strategy = strategyForField(field, policy: conflict.mergePolicy)
        applied[field] = strategy
        switch strategy {
        case .keepBothCopies:
            keepBothFields.append(field)
        case .lastWriterWins:
            lastWriterWinsFields.append(field)
        }
    }

    // Build the merged patch:
    // - Start from server's current properties (server wins on every
    //   conflicting field — keep-both fields are spawned to a sibling
    //   below, the original retains server state).
    // - Layer client patch values for any field NOT in `conflictingFields`.
    var merged = conflict.current.properties
    let conflictingSet = Set(conflict.conflictingFields)
    for (key, value) in conflict.clientPatch {
        if !conflictingSet.contains(key) {
            merged[key] = value
        }
    }

    var spawnedId: String?
    if !keepBothFields.isEmpty {
        spawnedId = try await keepBothFlow(
            transport: transport,
            originalItemId: itemId,
            keepBothFields: keepBothFields,
            clientPatch: conflict.clientPatch,
            current: conflict.current
        )
    }

    return ConflictResolutionOutcome(
        mergedProperties: merged,
        conflictedCopyId: spawnedId,
        appliedStrategies: applied
    )
}

/// Resolve the per-field strategy. Field-level entries override the policy
/// `default`; both fall back to `last_writer_wins` when absent (legacy
/// servers that don't emit `merge_policy`, or unclassified fields).
func strategyForField(
    _ field: String,
    policy: MergePolicy?
) -> MergePolicyStrategy {
    if let entry = policy?.fields?[field] { return entry }
    if let fallback = policy?.`default` { return fallback }
    return .lastWriterWins
}

// MARK: - Keep-both flow

/// Spawns a sibling item carrying the client's in-flight values for the
/// keep-both fields, server values for the rest. The new item is tagged
/// `conflicted-copy` inline on the create call (no two-step `metadata.addTags`
/// dance — `CreateItemInput.tags` is supported on the wire as of V0).
///
/// The original item is left to the merged update in
/// ``handleConflictUpdateWithStats`` — it carries the server's winning
/// state for every conflicting field, including the keep-both ones.
///
/// We need the item's `type` to spawn the sibling and the SDK doesn't carry
/// it on the conflict response, so we fetch the item once. This adds one
/// extra round-trip on conflict resolution; conflicts are rare and this
/// avoids threading the type through every call site (the design picked
/// in the plan).
func keepBothFlow(
    transport: any Transport,
    originalItemId: String,
    keepBothFields: [String],
    clientPatch: [String: JSONValue],
    current: ConflictSnapshot
) async throws -> String {
    // Fetch the original to learn its type. On the synced path this hits
    // the server, but conflicts are rare; the alternative is plumbing the
    // type through every conflict call site.
    let originalResponse: ItemResponse = try await transport.request(
        method: .get,
        path: "/items/\(originalItemId)",
        body: nil,
        query: nil
    )
    let typeId = originalResponse.item.type

    // Compose the sibling's properties: server's `current` for everything,
    // overlaid by the client's in-flight values for the keep-both fields
    // (and only those fields — non-keep-both client edits stay on the
    // original via the merged update).
    var properties = current.properties
    for field in keepBothFields {
        if let clientValue = clientPatch[field] {
            properties[field] = clientValue
        }
    }

    let input = CreateItemInput(
        type: typeId,
        properties: properties,
        tags: [conflictedCopyTag]
    )

    let response: ItemResponse = try await transport.request(
        method: .post,
        path: "/items",
        body: input,
        query: nil
    )
    return response.item.id
}

// MARK: - Legacy entry point

/// Last-writer-wins auto-merge — server wins on conflicting fields, client
/// wins elsewhere. Equivalent to applying `last_writer_wins` to every field.
/// Retained for tests and as a primitive used by ``autoMergeWithPolicy``.
func autoMerge(conflict: ConflictData) -> [String: JSONValue] {
    var merged = conflict.current.properties
    for (key, value) in conflict.clientPatch {
        if !conflict.conflictingFields.contains(key) {
            merged[key] = value
        }
    }
    return merged
}
