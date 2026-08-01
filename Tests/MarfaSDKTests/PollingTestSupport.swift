import Testing

/// Polls a MainActor-isolated condition until it holds or the timeout
/// elapses, recording an issue on expiry. Reactive-query suites poll
/// rather than assume immediate visibility, since queries update from
/// event streams and initial-load tasks.
///
/// The 5s default absorbs CI hosts that run 5-10x slower than local
/// Apple silicon — a 500ms ceiling produced flakes on CI without ever
/// firing locally. Pass a tighter `timeout:` when an assertion depends
/// on one; nothing relies on the default.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(5),
    every: Duration = .milliseconds(10),
    _ condition: @MainActor () async throws -> Bool
) async throws {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < timeout {
        if try await condition() { return }
        try await Task.sleep(for: every)
    }
    if try await condition() { return }
    Issue.record("waitUntil: condition never satisfied within \(timeout)")
}
