import Foundation
import Synchronization

/// Runs synchronous work, such as a call into the core, off the cooperative pool on at most `limit` threads at once,
/// at the priority of the task that asked.
///
/// Work beyond the limit waits without holding a thread, and the highest priority waiting starts first, the earliest
/// asked first among equals. A thread runs at the quality of service its job's priority maps to, but never below
/// utility: every call into the core takes the store's connection lock, which does not pass its holder's priority to a
/// waiter, so a call at background priority holding it could keep a call the person is waiting on waiting for as long
/// as the system defers the thread. The core lowers its own watch threads to utility and no further for the same reason.
final class CoreQueue: Sendable {
    /// Calls into the open core: reads, writes and the queue.
    static let calls = CoreQueue(limit: max(4, ProcessInfo.processInfo.activeProcessorCount))

    /// Work that can block for a long time on the network, the keychain or a hydration, kept apart so it never
    /// holds up ``calls``.
    static let blocking = CoreQueue(limit: max(8, ProcessInfo.processInfo.activeProcessorCount))

    private struct Pending {
        let priority: TaskPriority
        let sequence: UInt64
        let start: @Sendable () -> Void
        let abandon: @Sendable () -> Void
    }

    /// One call's side of a cancellation, so the cancel and the submit agree on who resumes the caller.
    private final class Ticket: Sendable {
        private let state = Mutex((canceled: false, sequence: UInt64?.none))

        var isCanceled: Bool { state.withLock { $0.canceled } }

        /// Whether the call is still wanted, in which case `enqueue` has run under the ticket's lock.
        func admit(_ enqueue: () -> UInt64) -> Bool {
            state.withLock { state in
                if state.canceled { return false }
                state.sequence = enqueue()
                return true
            }
        }

        /// The sequence to take back out of the queue, if the call was queued.
        func cancel() -> UInt64? {
            state.withLock { state in
                state.canceled = true
                return state.sequence
            }
        }
    }

    private struct State {
        var running = 0
        var sequence: UInt64 = 0
        var pending: [Pending] = []
    }

    let limit: Int
    private let state = Mutex(State())

    init(limit: Int) {
        precondition(limit > 0, "a queue needs room for one job")
        self.limit = limit
    }

    /// How many jobs wait for room.
    var waitingCount: Int { state.withLock { $0.pending.count } }

    /// Runs `work` and returns what it returns, translating the core's errors.
    ///
    /// A task canceled while its job waits, or before it asks, leaves the queue and throws `canceled` without
    /// running `work`. A job that has started runs to its end. `cancelable: false` is for work that must happen
    /// whatever the task, such as releasing the store.
    func run<T: Sendable>(cancelable: Bool = true, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let priority = Task.currentPriority
        guard cancelable else { return try await enqueue(Ticket(), priority, work) }
        let ticket = Ticket()
        return try await withTaskCancellationHandler {
            try await enqueue(ticket, priority, work)
        } onCancel: {
            if let sequence = ticket.cancel() { abandon(sequence) }
        }
    }

    private func enqueue<T: Sendable>(
        _ ticket: Ticket, _ priority: TaskPriority, _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let job = Job(work)
        return try await withCheckedThrowingContinuation { continuation in
            let queued = ticket.admit {
                submit(priority) {
                    if ticket.isCanceled {
                        job.discard()
                        continuation.resume(throwing: Self.canceled)
                    } else {
                        continuation.resume(with: job.run())
                    }
                } abandon: {
                    job.discard()
                    continuation.resume(throwing: Self.canceled)
                }
            }
            if !queued {
                job.discard()
                continuation.resume(throwing: Self.canceled)
            }
        }
    }

    private static let canceled = MarfaError.canceled(message: "the call was canceled")

    /// Takes a job still waiting out of the queue and tells its caller; does nothing for a job that has started.
    private func abandon(_ sequence: UInt64) {
        let removed = state.withLock { state -> Pending? in
            guard let index = state.pending.firstIndex(where: { $0.sequence == sequence }) else { return nil }
            return state.pending.remove(at: index)
        }
        removed?.abandon()
    }

    private func submit(
        _ priority: TaskPriority, _ start: @escaping @Sendable () -> Void, abandon: @escaping @Sendable () -> Void
    ) -> UInt64 {
        let (sequence, next) = state.withLock { state -> (UInt64, Pending?) in
            state.sequence += 1
            let sequence = state.sequence
            state.pending.append(Pending(priority: priority, sequence: sequence, start: start, abandon: abandon))
            return (sequence, take(&state))
        }
        if let next { dispatch(next) }
        return sequence
    }

    /// The pending job to start now, if there is room for one.
    private func take(_ state: inout State) -> Pending? {
        guard state.running < limit else { return nil }
        guard
            let best = state.pending.indices.min(by: {
                let (a, b) = (state.pending[$0], state.pending[$1])
                return a.priority != b.priority ? a.priority > b.priority : a.sequence < b.sequence
            })
        else { return nil }
        state.running += 1
        return state.pending.remove(at: best)
    }

    private func dispatch(_ job: Pending) {
        // `enforceQoS`: a block submitted from a thread of a higher class, such as a finished job's, otherwise runs at
        // that class instead of its own.
        let item = DispatchWorkItem(
            qos: DispatchQoS(qosClass: Self.qos(job.priority), relativePriority: 0), flags: .enforceQoS
        ) {
            [self] in
            job.start()
            let next = state.withLock { state -> Pending? in
                state.running -= 1
                return take(&state)
            }
            if let next { dispatch(next) }
        }
        DispatchQueue.global(qos: Self.qos(job.priority)).async(execute: item)
    }

    static func qos(_ priority: TaskPriority) -> DispatchQoS.QoSClass {
        if priority.rawValue >= 0x21 { return .userInteractive }
        if priority >= .high { return .userInitiated }
        if priority >= .medium { return .default }
        return .utility
    }
}

/// Releases the work before the caller resumes, so nothing it captured still
/// holds the core, and with it the store, once the call has returned.
private final class Job<T: Sendable>: Sendable {
    private let work: Mutex<(@Sendable () throws -> T)?>

    init(_ work: @escaping @Sendable () throws -> T) {
        self.work = Mutex(work)
    }

    /// Drops the work of a job that will not run.
    func discard() { work.withLock { $0 = nil } }

    func run() -> Result<T, any Error> {
        guard let work = self.work.withLock({ $0.take() }) else {
            preconditionFailure("a job runs once")
        }
        return Result { try translated(work) }
    }
}
