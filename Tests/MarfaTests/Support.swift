import Foundation
import MarfaCoreNames
import Synchronization
import Testing

@testable import Marfa

func temporaryStore() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "marfa-\(UUID()).sqlite")
}

func eventually(_ what: String, within seconds: Double = 5, _ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(seconds)
    while try await !condition() {
        guard Date.now < deadline else {
            Issue.record("never: \(what)")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

struct Unfinished: Error, CustomStringConvertible {
    let what: String
    var description: String { "\(what) did not finish" }
}

/// A suite's time limit cancels a test, and cancellation cannot end an
/// await that ignores it, such as a task's value or a continuation nobody
/// resumes: a test waiting on one would hang past its limit.
func bounded<T: Sendable>(
    _ what: String, within seconds: Double = 10, _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let answer = Answer(continuation)
        let job = Job(work)
        Task { answer.resume(with: await job.run()) }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            answer.resume(with: .failure(Unfinished(what: what)))
        }
    }
}

/// Releases the work before answering, so a caller that then drops a working
/// copy finds nothing else holding its store.
private final class Job<T: Sendable>: Sendable {
    private let work: Mutex<(@Sendable () async throws -> T)?>

    init(_ work: @escaping @Sendable () async throws -> T) {
        self.work = Mutex(work)
    }

    func run() async -> Result<T, any Error> {
        guard let work = self.work.withLock({ $0.take() }) else {
            preconditionFailure("a job runs once")
        }
        do {
            return .success(try await work())
        } catch {
            return .failure(error)
        }
    }
}

private final class Answer<T: Sendable>: Sendable {
    private let waiting: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        waiting = Mutex(continuation)
    }

    func resume(with result: Result<T, any Error>) {
        waiting.withLock { $0.take() }?.resume(with: result)
    }
}

final class Heard: Sendable {
    private final class Log: Sendable {
        let entries = Mutex<[(at: Date, change: Marfa.Change)]>([])
    }

    private let log: Log
    private let listening: Task<Void, Never>

    init(_ stream: AsyncStream<Marfa.Change>) {
        let log = Log()
        self.log = log
        listening = Task {
            for await change in stream {
                log.entries.withLock { $0.append((.now, change)) }
            }
        }
    }

    var all: [Marfa.Change] { log.entries.withLock { $0.map(\.change) } }
    var timed: [(at: Date, change: Marfa.Change)] { log.entries.withLock { $0 } }

    var locals: [Marfa.Change] {
        all.filter { if case .local = $0.origin { true } else { false } }
    }

    var saves: [(at: Date, change: Marfa.Change)] {
        timed.filter { if case .saved = $0.change.origin { true } else { false } }
    }

    var stops: [Marfa.Change] {
        all.filter { if case .stopped = $0.origin { true } else { false } }
    }

    func stop() {
        listening.cancel()
    }
}

/// For what a real core cannot be made to do on cue.
///
/// A follow that ends late, fails, or speaks after it was replaced. It keeps
/// the core's rules: one stream at a time, let go only as the follow ends,
/// `ended` told a moment after `stop`, and hydration and catch-up refused
/// while a follow holds the stream.
final class FakeCore: Core, @unchecked Sendable {
    struct Follow {
        let listener: any CoreChangeListener
        let holdsStream: Bool
        var stopped = false
        var ended = false
    }

    struct State {
        var handle = CoreHandle.writer
        var follows: [Follow] = []
        var streamHeld = false
        var caughtUp = CoreCatchUpReport(applied: 0, skipped: 0, cursor: "1", reachedHead: true)
        var drained = CoreDrainReport(
            sent: 0, held: 0, verdicts: [], stopped: nil, unclaimedSources: [], retryAfterSeconds: nil)
        var dataVersion: Int64 = 0
        var gate: DispatchSemaphore?
        var gated = false
        var readsFail: CoreMarfaError?
        var withdrawable: Set<String> = []
    }

    let state = Mutex(State())

    static func reader() -> FakeCore {
        let core = FakeCore(noHandle: .init())
        core.state.withLock { $0.handle = .reader }
        return core
    }

    static func writer() -> FakeCore {
        FakeCore(noHandle: .init())
    }

    var follows: [Follow] { state.withLock { $0.follows } }

    override func heldHandle() -> CoreHandle {
        state.withLock { $0.handle }
    }

    override func follow(listener: any CoreChangeListener) -> CoreSubscription {
        let (index, refused) = state.withLock { state in
            let refused = state.streamHeld
            state.follows.append(Follow(listener: listener, holdsStream: !refused))
            state.streamHeld = true
            return (state.follows.count - 1, refused)
        }
        if refused {
            later {
                self.end(index, with: .Invalid(message: Self.refusal))
            }
        }
        return FakeSubscription { [self] in
            state.withLock { $0.follows[index].stopped = true }
            later { self.end(index, with: nil) }
        }
    }

    func fail(_ index: Int, with error: CoreMarfaError) {
        end(index, with: error)
    }

    /// No real core ends a follow twice; the feed must ignore it.
    func endAgain(_ index: Int, with error: CoreMarfaError?) {
        state.withLock { $0.follows[index].listener }.ended(error: error)
    }

    func change(_ index: Int, _ change: CoreChange) {
        state.withLock { $0.follows[index].listener }.changed(change: change)
    }

    override func hydrate(types: [String], tier: CoreTier) throws -> CoreHydrateReport {
        try refreshing()
        return CoreHydrateReport(types: types, tier: tier, edgeTypes: [], items: 0, edges: 0, pages: 1, cursor: "1")
    }

    override func catchUp() throws -> CoreCatchUpReport {
        try refreshing()
        return state.withLock { $0.caughtUp }
    }

    override func withdraw(id: String) throws -> Bool {
        state.withLock { $0.withdrawable.remove(id) != nil }
    }

    override func drain() throws -> CoreDrainReport {
        state.withLock { $0.drained }
    }

    override func dataVersion() throws -> Int64 {
        let gate = state.withLock { state in
            defer { state.gate = nil }
            state.gated = state.gate != nil
            return state.gate
        }
        gate?.wait()
        return try state.withLock { state in
            if let error = state.readsFail { throw error }
            return state.dataVersion
        }
    }

    func save() {
        state.withLock { $0.dataVersion += 1 }
    }

    func holdNextRead() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        state.withLock { $0.gate = gate }
        return gate
    }

    var aReadWasHeld: Bool { state.withLock { $0.gated } }

    static let refusal =
        "this working copy is already hydrating, catching up or following; one at a time moves its cursor"

    private func refreshing() throws {
        let held = state.withLock { $0.streamHeld }
        if held {
            throw CoreMarfaError.Invalid(message: Self.refusal)
        }
    }

    private func end(_ index: Int, with error: CoreMarfaError?) {
        let listener = state.withLock { state -> (any CoreChangeListener)? in
            guard !state.follows[index].ended else { return nil }
            state.follows[index].ended = true
            if state.follows[index].holdsStream { state.streamHeld = false }
            return state.follows[index].listener
        }
        listener?.ended(error: error)
    }

    private func later(_ work: @escaping @Sendable () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50), execute: work)
    }
}

final class FakeSubscription: CoreSubscription, @unchecked Sendable {
    private let onStop: @Sendable () -> Void

    init(onStop: @escaping @Sendable () -> Void) {
        self.onStop = onStop
        super.init(noHandle: .init())
    }

    required init(unsafeFromHandle handle: UInt64) {
        fatalError("a fake subscription has no handle")
    }

    override func stop() {
        onStop()
    }
}

func write(_ kind: WriteKind, item: String?, target: String? = nil, edge: String? = nil) -> QueuedWrite {
    QueuedWrite(
        id: "q-\(UUID())", kind: kind, itemId: item, targetId: target, edgeId: edge, namespace: nil, tag: nil,
        blob: nil, baseVersion: nil, idempotencyKey: "k", dependsOn: [], follows: nil, verdict: nil, answer: nil,
        refusals: 0, queuedAt: "", answeredAt: nil)
}
