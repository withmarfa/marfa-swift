import Foundation

/// Thrown by `waitUntil` when `condition` never becomes true before the
/// timeout, so the failure names what was awaited and for how long
/// instead of leaving the caller's next line — and the assertion after
/// it — to run against state the wait never established.
public struct WaitUntilTimeoutError: Error, CustomStringConvertible {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

/// Polls a main-actor-isolated condition until it holds or the timeout
/// elapses, throwing on expiry. Reactive-query suites poll rather than
/// assume immediate visibility, since queries update from event streams
/// and initial-load tasks.
///
/// Keeps its own deadline instead of leaning on Swift Testing's
/// `.timeLimit` trait: that trait's granularity bottoms out at a minute,
/// far coarser than these sub-second waits.
///
/// The 5s default absorbs CI hosts that run 5-10x slower than local
/// Apple silicon — a 500ms *default* produced flakes on CI without ever
/// firing locally. That is a claim about the default, not a floor for the
/// argument, and the distinction is worth keeping straight: sub-second
/// bounds are passed deliberately all over this repository, most of them
/// to `SyncEngineTestKit.waitUntil`, which requires `timeout:` precisely
/// so each call site states its own. Pass a tighter `timeout:` here when
/// an assertion depends on one, derived from the constant it is testing
/// rather than from what the machine usually manages; nothing relies on
/// the default.
///
/// **There is a second wait helper in this repository, and that is
/// deliberate.** `SyncEngineTestKit.waitUntil` is `nonisolated` and takes
/// a `@Sendable` condition, because its call sites await actors from off
/// the main actor. This one is `@MainActor` and takes a `@MainActor`
/// condition. The two bodies are near-identical, so a sweep that compares
/// function *bodies* concludes they are duplicates and should be folded
/// together — which is wrong, and costs every one of those call sites an
/// isolation annotation to paper over. In strict-concurrency Swift the
/// isolation modifier is part of a function's meaning, so one helper per
/// repository cannot hold across two isolation domains. **Diff what the
/// compiler reads, not what the eye matches.**
@MainActor
public func waitUntil(
    timeout: Duration = .seconds(5),
    every: Duration = .milliseconds(10),
    description: String,
    _ condition: @MainActor () async throws -> Bool
) async throws {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < timeout {
        if try await condition() { return }
        // Yield so the debounced refetch task lands on the main actor.
        // Probably redundant beside the sleep below, but "probably" across
        // the reactive-query suites is not worth the flakiness risk;
        // dropping it is a separate question to ask deliberately.
        await Task.yield()
        try await Task.sleep(for: every)
    }
    // Re-check after the loop so a condition that becomes true exactly at
    // the deadline passes rather than racing the clock.
    if try await condition() { return }
    throw WaitUntilTimeoutError(
        description: "timed out after \(timeout) waiting for \(description)"
    )
}
