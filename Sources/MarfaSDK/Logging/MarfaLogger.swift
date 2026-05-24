import Foundation
import os

/// Thin wrapper that gives every SDK subsystem a consistently-configured
/// `Logger` and `OSSignposter`. One instance per category.
///
/// Subsystem is fixed to `"sdk.marfa"` so consumers can filter logs and
/// signposts to the SDK in Console.app or Instruments. Active categories:
/// `"transport"`, `"sse"`, `"sync"` (plus the `"disabled"` sentinel for
/// test suites).
///
/// ## Log shape
///
/// Message strings follow `event.name key=value key=value` so they're
/// readable in Console.app and greppable from the `log` CLI. Apps
/// consuming the SDK should mirror this shape in their own
/// `os.Logger` calls for sync-related events. Conventional keys:
///
///     request_id     — X-Request-ID on the wire (stamped by transport)
///     method, path   — HTTP method and endpoint path
///     status         — HTTP status code
///     url_error      — URLError raw value on connection failures
///     kind           — PendingMutationRecord.Kind raw value
///     item_id        — local or server item ID for sync events
///     attempt        — 1-based attempt count
///     code           — server-reported error code
///
/// Missing values are written as `-` so every entry has consistent key
/// presence.
///
/// ## Privacy
///
/// Privacy is the caller's responsibility at the interpolation site:
///
///     logger.log.info("http.request method=\(method, privacy: .public) path=\(path, privacy: .public) request_id=\(requestId, privacy: .public)")
///
/// Request IDs, paths, statuses, error codes, and mutation kinds are
/// `.public` — they're diagnostic, not sensitive. Bearer tokens and full
/// request/response bodies belong behind `privacy: .private` and are only
/// logged when `ClientConfiguration.debugLogging` is on.
public struct MarfaLogger: Sendable {

    /// Subsystem used by every SDK logger and signposter.
    public static let subsystem = "sdk.marfa"

    public let log: Logger
    public let signposter: OSSignposter

    public init(category: String) {
        self.log = Logger(subsystem: Self.subsystem, category: category)
        self.signposter = OSSignposter(subsystem: Self.subsystem, category: category)
    }

    /// Disabled logger for use in tests when captured output would be noise.
    public static let disabled: MarfaLogger = {
        // A logger writing to the "disabled" category is still a live Logger;
        // the tests just don't assert against its output.
        MarfaLogger(category: "disabled")
    }()
}
