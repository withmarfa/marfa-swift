import Foundation
import Synchronization

/// Runs synchronous work, such as a call into the core, off the cooperative pool on at most `limit` threads at once,
/// at the priority of the task that asked.
///
/// Work beyond the limit waits without holding a thread, and the highest priority waiting starts first, the earliest
/// asked first among equals. A thread runs at the quality of service its job's priority maps to, so a background read
/// does not compete with a call the person is waiting on.
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
    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let priority = Task.currentPriority
        let job = Job(work)
        return try await withCheckedThrowingContinuation { continuation in
            submit(priority) { continuation.resume(with: job.run()) }
        }
    }

    private func submit(_ priority: TaskPriority, _ start: @escaping @Sendable () -> Void) {
        let next = state.withLock { state -> Pending? in
            state.sequence += 1
            state.pending.append(Pending(priority: priority, sequence: state.sequence, start: start))
            return take(&state)
        }
        if let next { dispatch(next) }
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
        DispatchQueue.global(qos: Self.qos(job.priority)).async { [self] in
            job.start()
            let next = state.withLock { state -> Pending? in
                state.running -= 1
                return take(&state)
            }
            if let next { dispatch(next) }
        }
    }

    static func qos(_ priority: TaskPriority) -> DispatchQoS.QoSClass {
        if priority.rawValue >= 0x21 { return .userInteractive }
        if priority >= .high { return .userInitiated }
        if priority >= .medium { return .default }
        if priority >= .low { return .utility }
        return .background
    }
}

/// Releases the work before the caller resumes, so nothing it captured still
/// holds the core, and with it the store, once the call has returned.
private final class Job<T: Sendable>: Sendable {
    private let work: Mutex<(@Sendable () throws -> T)?>

    init(_ work: @escaping @Sendable () throws -> T) {
        self.work = Mutex(work)
    }

    func run() -> Result<T, any Error> {
        guard let work = self.work.withLock({ $0.take() }) else {
            preconditionFailure("a job runs once")
        }
        return Result { try translated(work) }
    }
}
