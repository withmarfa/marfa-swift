import Foundation
import MarfaSDK

/// Test fake for ``DeviceFlowClock``. Records every `sleep(for:)` request
/// and suspends until the test resumes it via ``advance(by:)`` or
/// ``fail(with:)``. `now()` returns the manually-advanced time. Lets
/// cadence tests assert observed sleep durations without burning real
/// wall-clock time.
///
/// Typical usage in a test:
///
/// ```swift
/// let clock = ManualDeviceFlowClock()
/// let task = Task { try await handle.awaitToken() }
/// _ = await clock.nextSleepRequest()  // wait until loop enters sleep
/// clock.advance(by: 5)                  // resume the sleep
/// ```
///
/// External `Task.cancel()` on a task that's suspended inside
/// `sleep(for:)` resolves to `CancellationError` via
/// `withTaskCancellationHandler` — exercising the same cancellation
/// path the production clock honours via `Task.sleep`.
public final class ManualDeviceFlowClock: DeviceFlowClock, @unchecked Sendable {

    private let lock = NSLock()
    private var _currentTime: Date
    private var _recordedSleeps: [TimeInterval] = []

    // The polling loop's active sleep — at most one at a time.
    private var pendingResume: CheckedContinuation<Void, Error>?

    // Coordination for `nextSleepRequest()` — durations that arrived
    // before the test asked, plus the test waiter that's currently
    // blocked waiting for the next one.
    private var unconsumedSleepDurations: [TimeInterval] = []
    private var pendingWaiter: CheckedContinuation<TimeInterval, Never>?

    public init(initialTime: Date = Date()) {
        self._currentTime = initialTime
    }

    /// Every sleep duration the clock has been asked to wait for, in
    /// chronological order. Lets cadence tests assert cadence (e.g.
    /// `slow_down` incremented the second sleep by 5).
    public var recordedSleeps: [TimeInterval] {
        lock.withLock { _recordedSleeps }
    }

    /// The current simulated time. Mutated by ``advance(by:)``.
    public var currentTime: Date {
        lock.withLock { _currentTime }
    }

    public func now() -> Date {
        lock.withLock { _currentTime }
    }

    public func sleep(for duration: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    _recordedSleeps.append(duration)
                    if let waiter = pendingWaiter {
                        pendingWaiter = nil
                        waiter.resume(returning: duration)
                    } else {
                        unconsumedSleepDurations.append(duration)
                    }
                    // Handle the race where the task is already cancelled
                    // by the time we enter the lock — onCancel may have
                    // already fired (and observed pendingResume == nil).
                    if Task.isCancelled {
                        cont.resume(throwing: CancellationError())
                    } else {
                        pendingResume = cont
                    }
                }
            }
        } onCancel: { [self] in
            lock.withLock {
                if let cont = pendingResume {
                    pendingResume = nil
                    cont.resume(throwing: CancellationError())
                }
            }
        }
    }

    /// Suspends until the polling loop next calls `sleep(for:)`. Returns
    /// the duration it asked to wait for. If a sleep arrived before this
    /// call (no waiter was active when it landed), returns immediately
    /// with that buffered duration.
    public func nextSleepRequest() async -> TimeInterval {
        await withCheckedContinuation { (cont: CheckedContinuation<TimeInterval, Never>) in
            lock.withLock {
                if !unconsumedSleepDurations.isEmpty {
                    cont.resume(returning: unconsumedSleepDurations.removeFirst())
                } else {
                    pendingWaiter = cont
                }
            }
        }
    }

    /// Advances the clock by `duration` and resumes the polling loop's
    /// active sleep so it returns from `sleep(for:)`.
    public func advance(by duration: TimeInterval) {
        lock.withLock {
            _currentTime = _currentTime.addingTimeInterval(duration)
            if let cont = pendingResume {
                pendingResume = nil
                cont.resume(returning: ())
            }
        }
    }

    /// Resumes the polling loop's active sleep by throwing `error` from
    /// it. Useful for asserting error paths without relying on external
    /// `Task.cancel()`.
    public func fail(with error: Error) {
        lock.withLock {
            if let cont = pendingResume {
                pendingResume = nil
                cont.resume(throwing: error)
            }
        }
    }

    /// Sets the simulated time to `time` without resuming any pending
    /// sleep. Useful for arranging "already expired" scenarios before
    /// the loop's first iteration.
    public func setNow(_ time: Date) {
        lock.withLock { _currentTime = time }
    }
}
