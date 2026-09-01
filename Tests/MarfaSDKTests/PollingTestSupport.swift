/// Thrown by `waitUntil` when `condition` never becomes true before the
/// timeout, so the failure names what was awaited and for how long
/// instead of leaving the caller's next line to run against state the
/// wait never established.
struct WaitUntilTimeoutError: Error, CustomStringConvertible {
    let description: String
}

/// Polls a MainActor-isolated condition until it holds or the timeout
/// elapses, throwing on expiry. Reactive-query suites poll rather than
/// assume immediate visibility, since queries update from event streams
/// and initial-load tasks.
///
/// Keeps its own deadline instead of leaning on Swift Testing's
/// `.timeLimit` trait: that trait's granularity bottoms out at a minute,
/// far coarser than these sub-second waits.
///
/// The 5s default absorbs CI hosts that run 5-10x slower than local
/// Apple silicon — a 500ms ceiling produced flakes on CI without ever
/// firing locally. Pass a tighter `timeout:` when an assertion depends
/// on one; nothing relies on the default.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(5),
    every: Duration = .milliseconds(10),
    description: String,
    _ condition: @MainActor () async throws -> Bool
) async throws {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < timeout {
        if try await condition() { return }
        try await Task.sleep(for: every)
    }
    if try await condition() { return }
    throw WaitUntilTimeoutError(
        description: "timed out after \(timeout) waiting for \(description)"
    )
}
