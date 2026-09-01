import Foundation

/// Thrown by `waitForCondition` when `condition` never becomes true before
/// the deadline, so the failure names what was awaited and for how long
/// instead of surfacing as a bare, unrelated `CancellationError`.
public struct WaitForConditionTimeoutError: Error, CustomStringConvertible {
    public let description: String
}

/// Polls `condition` up to `timeout` by yielding the main actor on each
/// check, throwing `WaitForConditionTimeoutError` if the deadline is
/// exceeded.
///
/// Keeps its own deadline instead of leaning on Swift Testing's
/// `.timeLimit` trait: that trait's granularity bottoms out at a minute,
/// far coarser than the sub-second reactive-query waits this exists for.
@MainActor
public func waitForCondition(
    timeout: Duration,
    description: String,
    condition: () -> Bool
) async throws {
    let deadline = ContinuousClock().now + timeout
    while !condition() {
        guard ContinuousClock().now < deadline else {
            throw WaitForConditionTimeoutError(
                description: "timed out after \(timeout) waiting for \(description)"
            )
        }
        // Yield so the debounced refetch task lands on the main actor.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(10))
    }
}
