import Foundation

/// Why a one-shot catch-up import declined to run.
///
/// Separate from ``MarfaError`` on purpose: that hierarchy is shaped around an
/// HTTP response — a code, a status and a server message — and this refusal
/// never reaches the network. Giving it a borrowed status would make the
/// failure read as something the server said.
public enum InitialSyncError: Error, Sendable {

    /// The local mutation queue still holds writes that have not replayed, so
    /// importing the server's rows over them would discard local work.
    ///
    /// ``SyncEngine/performInitialSync(pageSize:)`` overwrites every row it
    /// receives, with no version check and no merge: the conflict machinery
    /// only runs on an outbound update meeting a 409. So an edit made offline
    /// and still queued is replaced by the server's older body, silently, and
    /// the queued mutation then replays on top of a row the user can no longer
    /// see the earlier state of.
    ///
    /// The queue is the thing to clear first. On a synced client that means
    /// letting the engine drain — `start()` replays after the stream closes,
    /// and ``SyncEngine/hasPendingMutations`` reports when it is done — and
    /// then asking again.
    ///
    /// - Parameter count: How many writes were outstanding when the import was
    ///   asked for. Worth surfacing rather than a bare "try later": a count
    ///   that does not fall across retries is a stuck queue rather than a busy
    ///   one, and those need different answers from a person.
    case pendingMutations(count: Int)

    /// A page said more rows were waiting and carried no cursor to reach them
    /// with, so the import cannot see the whole server side and stops.
    ///
    /// The import is not only a read. It takes the ids it saw as the entire
    /// server side and removes every stored row absent from that set, so an
    /// answer that stops early is not a smaller import — it is a deletion of
    /// everything the unread pages would have named. Stopping leaves the store
    /// exactly as it was and the next cycle asks again.
    ///
    /// Marfa's own server cannot produce this pair: its item store sets a
    /// cursor only when there is more to fetch. This SDK also talks to
    /// self-hosted servers, where that is somebody else's implementation
    /// detail rather than a promise the route makes.
    ///
    /// - Parameters:
    ///   - route: The route that answered this way, so a report names which of
    ///     the import's passes stopped rather than only that one did.
    ///   - imported: How many rows had been written when it stopped. A run that
    ///     always stops at the same count is a server paginating wrongly at a
    ///     fixed boundary rather than a transient one.
    // Labeled `route:` rather than `path:` deliberately. `RouteCoverageTests`
    // treats a route-shaped `path:` argument outside a transport call as an
    // HTTP call that escaped its scan, and that guard is worth more than the
    // label.
    case unresumablePage(route: String, imported: Int)
}

extension InitialSyncError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .pendingMutations(let count):
            let writes = count == 1 ? "1 local write" : "\(count) local writes"
            return """
                The initial sync was not run because \(writes) have not yet \
                reached the server. Importing now would overwrite them. Let the \
                sync engine drain its queue and ask again.
                """
        case .unresumablePage(let route, let imported):
            let rows = imported == 1 ? "1 row" : "\(imported) rows"
            return """
                The initial sync stopped after \(rows) because \(route) reported \
                more results and returned no cursor to continue from. Nothing \
                was changed locally: finishing a partial answer would delete \
                every row the remaining pages would have named.
                """
        }
    }
}

// Conformance from the start rather than added after a consumer reports a case
// index. `localizedDescription` is what a SwiftUI error row shows, and without
// this it falls through to the NSError bridge and renders
// "The operation couldn't be completed. (MarfaSDK.InitialSyncError error 0.)" —
// which is what happened to `OAuthDiscoveryError` and cost an afternoon.
extension InitialSyncError: LocalizedError {
    public var errorDescription: String? { description }
}
