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
/// and turns a correct engine red. Use ``awaitCondition(every:description:_:)``
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
/// about the network. ``awaitCondition(every:description:_:)`` keeps none and
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
/// ``awaitCondition(every:description:_:)`` below is `@MainActor` and takes a
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

/// Polls a main-actor condition until it holds, with **no test-owned
/// deadline**. The suite's `.timeLimit` trait owns the clock.
///
/// This is the shape for a condition that can be *starved* rather than merely
/// delayed. A test-owned bound on such a condition is a clock wearing an
/// assertion's clothes: nothing in the output says `timed out`, no elapsed
/// figure appears and no budget is named, so a load-induced red sends the next
/// reader to study a diff that is fine. Most suites in this repository
/// already carry `.timeLimit(.minutes(1))`, which means the budget exists and
/// a sub-second wait merely fires before it can.
///
/// A minute is coarse, and that is the point: a test that hangs for a minute
/// and then names itself a timeout is strictly more useful than one that fails
/// in half a second saying the wrong thing. **Every suite using this must
/// carry a `.timeLimit`,** or a starved condition hangs the run instead.
///
/// **And a `.timeLimit` bounds a *cancellable* wait only**, which is the part
/// that is easy to get wrong and was got wrong here once. The trait cancels
/// the test task; it does not kill it. Every poll below suspends in
/// `Task.sleep`, which throws on cancellation, so the trait reaches them. An
/// unstructured `Task` does not inherit that cancellation, and `await
/// someTask.value` on a non-throwing `Task` cannot throw `CancellationError`
/// at all — so a test awaiting one hangs forever under a trait that looks like
/// it covers the case. Wrap such a wait in `withTaskCancellationHandler` and
/// cancel the task in `onCancel:`, or keep its own bound.
@MainActor
public func awaitCondition(
    every: Duration = .milliseconds(10),
    description: String,
    _ condition: @MainActor () async throws -> Bool
) async throws {
    while true {
        if try await condition() { return }
        // The suite's time limit works by *cancelling* the test task, and
        // cancellation on its own reports only the trait's message — which
        // names a duration and not what was being waited for. Translating it
        // here is what makes `description` load-bearing rather than a string
        // every call site composes and nothing prints.
        do {
            try Task.checkCancellation()
            // Yield so the debounced refetch task lands on the main actor
            // before the sleep, for the same reason `waitUntil` does it.
            await Task.yield()
            try await Task.sleep(for: every)
        } catch is CancellationError {
            throw AwaitConditionCancelled(description: description)
        }
    }
}
