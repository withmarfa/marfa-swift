import Foundation

/// Time seam for ``DeviceFlow`` polling — `now()` is used for the local
/// device-code expiry check, `sleep(for:)` for the between-poll wait.
///
/// Production injects ``SystemDeviceFlowClock`` (wraps `Date()` and
/// `Task.sleep`). Tests inject a manual clock that records sleep
/// requests and lets the test resume them on demand — see
/// `ManualDeviceFlowClock` in `MymeSDKTestSupport`. Without this seam,
/// cadence assertions would require real wall-clock waits.
public protocol DeviceFlowClock: Sendable {
    func now() -> Date
    func sleep(for duration: TimeInterval) async throws
}

/// Production ``DeviceFlowClock`` — `Date()` + `Task.sleep`.
public struct SystemDeviceFlowClock: DeviceFlowClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(for duration: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}
