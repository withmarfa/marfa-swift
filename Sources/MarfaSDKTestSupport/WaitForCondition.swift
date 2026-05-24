import Foundation

/// Polls `condition` up to `timeout` by yielding the main actor on each check.
/// Throws `CancellationError` if the deadline is exceeded.
@MainActor
public func waitForCondition(
    timeout: Duration,
    condition: () -> Bool
) async throws {
    let deadline = ContinuousClock().now + timeout
    while !condition() {
        guard ContinuousClock().now < deadline else {
            throw CancellationError()
        }
        // Yield so the debounced refetch task lands on the main actor.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(10))
    }
}
