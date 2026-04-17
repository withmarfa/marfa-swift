import Foundation

/// Maximum number of conflict resolution retry attempts.
private let maxRetries = 3

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

/// Returns the resolved item plus the number of conflict-resolution retries
/// that fired (0 when the first attempt succeeded). Callers that surface a
/// "merged" event (e.g. ``SyncEngine`` for replay-time auto-merges) use the
/// retry count to decide whether to emit ``SyncEvent/conflictAutoMerged``.
func handleConflictUpdateWithStats(
    transport: any Transport,
    itemId: String,
    clientPatch: [String: JSONValue],
    version: Int,
    strategy: ConflictStrategy,
    resolver: ConflictResolver?,
    library: Bool? = nil
) async throws -> (item: Item, retries: Int) {
    var properties = clientPatch
    var currentVersion = version

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
            return (item: response.item, retries: attempt)

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
                clientPatch: clientPatch
            )

            switch strategy {
            case .auto:
                properties = autoMerge(conflict: conflict)
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

/// Auto-merges non-conflicting fields. Server wins on conflicting fields.
///
/// Starts from the server's current properties, then applies the client's
/// changes for any field that is NOT in the conflicting fields list.
func autoMerge(conflict: ConflictData) -> [String: JSONValue] {
    var merged = conflict.current.properties
    for (key, value) in conflict.clientPatch {
        if !conflict.conflictingFields.contains(key) {
            merged[key] = value
        }
    }
    return merged
}
