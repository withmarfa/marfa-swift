import Foundation

/// The network / sync lifecycle state of a ``SyncEngine``-backed client.
public enum ConnectionState: Sendable, Equatable, CustomStringConvertible {
    /// No network path is available.
    case offline
    /// A network path just became available; attempting to connect to the server.
    case connecting
    /// Connected to the server; SSE stream is idle (no pending backfill).
    case online
    /// Backfilling or replaying the mutation queue against the server.
    case syncing

    public var description: String {
        switch self {
        case .offline: return "offline"
        case .connecting: return "connecting"
        case .online: return "online"
        case .syncing: return "syncing"
        }
    }

    /// `true` when network is available (regardless of sync status).
    public var isReachable: Bool { self != .offline }
}
