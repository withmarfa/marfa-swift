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
