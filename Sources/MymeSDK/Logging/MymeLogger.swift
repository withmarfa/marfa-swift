import Foundation
import os

/// Thin wrapper that gives every SDK subsystem a consistently-configured
/// `Logger` and `OSSignposter`. One instance per category.
///
/// Subsystem is fixed to `"sdk.myme"` so consumers can filter logs and
/// signposts to the SDK in Console.app or Instruments. Active categories:
/// `"transport"`, `"retry"`, `"sse"`, `"keychain"`.
///
/// Privacy is the caller's responsibility at the interpolation site:
///
///     logger.log.info("\(method, privacy: .public) \(path, privacy: .public) \(status, privacy: .public)")
///
/// Bearer tokens and full bodies belong behind `privacy: .private`.
public struct MymeLogger: Sendable {

    /// Subsystem used by every SDK logger and signposter.
    public static let subsystem = "sdk.myme"

    public let log: Logger
    public let signposter: OSSignposter

    public init(category: String) {
        self.log = Logger(subsystem: Self.subsystem, category: category)
        self.signposter = OSSignposter(subsystem: Self.subsystem, category: category)
    }

    /// Disabled logger for use in tests when captured output would be noise.
    public static let disabled: MymeLogger = {
        // A logger writing to the "disabled" category is still a live Logger;
        // the tests just don't assert against its output.
        MymeLogger(category: "disabled")
    }()
}
