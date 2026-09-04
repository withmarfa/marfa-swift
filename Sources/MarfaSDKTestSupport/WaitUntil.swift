import Foundation

/// Thrown by `waitUntil` when `condition` never becomes true before the
/// timeout, so the failure names what was awaited and for how long
/// instead of leaving the caller's next line — and the assertion after
/// it — to run against state the wait never established.
public struct AwaitConditionCancelled: Error, CustomStringConvertible {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

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
/// **A deadline here is only honest for a condition that can be delayed but
/// not starved**, and most conditions in this suite can be starved. A
/// debounced refetch sitting behind several actor hops does not run slowly on
/// a loaded machine — it does not run at all until the machine gets to it, so
/// a bound expressed in milliseconds measures the runner rather than the code
/// and turns a correct engine red. Use `awaitCondition` in the test target
/// there and let the suite's `.timeLimit` own the clock. Pass a `timeout:`
/// here only when the bound is *derived from the constant it is testing* and
/// that derivation is written beside it.
///
/// The 5s default absorbs CI hosts that run 5-10x slower than local Apple
/// silicon — a 500ms *default* produced flakes on CI without ever firing
/// locally.
///
/// **Two helpers, and which one to reach for is the whole decision.** This one
/// keeps a deadline and is for a condition that can be *delayed* — a round
/// trip to a live server, where a bound in tens of seconds says something
/// about the network. `awaitCondition` in the test target keeps none and
/// is for a condition that can be *starved*, which is every in-process wait on
/// a debounced refetch or a drain behind several actor hops: those do not run
/// slowly on a loaded machine, they do not run until the machine reaches them,
/// so a bound in milliseconds measures the runner and reports it as logic.
///
/// Every surviving caller of this function is in the live-server suite and
/// passes a bound between fifteen and a hundred and twenty seconds, each
/// derived from what that call actually does against a real space. Nothing in
/// the repository passes a sub-second bound here any more.
///
/// **There is a second pair of these, and that is deliberate.**
/// `SyncEngineTestKit.awaitCondition` is `nonisolated` and takes a `@Sendable`
/// condition, because its call sites await actors from off the main actor;
/// `awaitCondition` in the test target below is `@MainActor` and takes a
/// `@MainActor` condition. The two bodies are near-identical, so a sweep that
/// compares function *bodies* concludes they are duplicates and should be
/// folded together — which is wrong, and costs every one of those call sites
/// an isolation annotation to paper over. In strict-concurrency Swift the
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
