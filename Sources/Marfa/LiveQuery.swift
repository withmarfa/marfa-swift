import Foundation
import MarfaCore
import Observation
import Synchronization

/// What a ``LiveQuery`` reads from its working copy, and what it shows until
/// the first read ends.
///
/// ``list(_:sort:)``, ``search(_:filters:limit:)``, ``item(_:)`` and ``queue``
/// cover the common reads. `init(placeholder:_:)` makes any other, such as
/// the edges to an item or a search that keeps each hit's score.
public struct Reading<Value: Sendable & Equatable>: Sendable {
    let placeholder: Value
    let read: @Sendable (WorkingCopy) async throws -> Value

    /// A reading whose `read` runs against the query's copy each time the
    /// query refreshes.
    ///
    /// `read` can run often and while the copy is closing, so it only reads.
    public init(placeholder: Value, _ read: @escaping @Sendable (WorkingCopy) async throws -> Value) {
        self.placeholder = placeholder
        self.read = read
    }
}

extension Reading where Value == [Item] {
    /// The items `filters` select, as `items.list(_:sort:)` answers them.
    ///
    /// `filters.limit` and `filters.offset` bound the result.
    public static func list(_ filters: ListFilters = ListFilters(), sort: Sort? = nil) -> Reading {
        Reading(placeholder: []) { copy in
            if let sort {
                try await copy.items.list(filters, sort: sort)
            } else {
                try await copy.items.list(filters)
            }
        }
    }

    /// The items a full-text search finds, best match first, as `search(_:filters:limit:)` answers it.
    ///
    /// Without a `limit` the result holds the copy's default number of hits.
    public static func search(_ text: String, filters: SearchFilters = SearchFilters(), limit: Int? = nil) -> Reading {
        Reading(placeholder: []) { copy in
            let hits =
                if let limit {
                    try await copy.search(text, filters: filters, limit: limit)
                } else {
                    try await copy.search(text, filters: filters)
                }
            return hits.map(\.item)
        }
    }
}

extension Reading where Value == Item? {
    /// One item, `nil` while the copy does not hold it or it is in the bin, as `items.get(_:)` answers.
    public static func item(_ id: String) -> Reading {
        Reading(placeholder: nil) { copy in try await copy.items.get(id) }
    }
}

extension Reading where Value == [QueuedWrite] {
    /// Every write the queue holds, as `queue.all()` answers.
    public static var queue: Reading {
        Reading(placeholder: []) { copy in try await copy.queue.all() }
    }
}

/// Whether a ``LiveQuery`` still hears its copy.
public enum Following: Sendable, Hashable {
    /// The query reads again on each change the copy tells.
    case live
    /// The copy's follow of the server failed with this error and the stream is
    /// still open: local writes still refresh the query.
    ///
    /// It returns to `live` on a server event, or a hydration or a catch-up
    /// that tells the stream a change. A catch-up that applies nothing tells
    /// nothing, so this can outlast the failure it names.
    case stopped(MarfaError)
    /// The stream finished, so the query no longer refreshes by itself: the
    /// copy was closed (the error is `nil`), or the core ended the stream on a
    /// fault, which is the error. ``LiveQuery/refresh()`` asks for a new stream.
    case ended(MarfaError?)
}

/// Rows, or one item, read from a working copy and read again whenever the copy
/// changes, for a view to show.
///
/// Reading a property in a SwiftUI view's `body` is all a view does to stay
/// current. The query opens one `changes()` stream of its copy and reads again
/// after each change that can alter a read, including a local write made
/// offline. A burst of changes causes the read in flight and at most one more,
/// and the result of a read made obsolete by a newer one is dropped. Releasing
/// the query ends its stream.
///
/// Create it on the main actor with the copy it reads; it reads that copy for
/// life, so a view for another copy makes another query. Assign ``reading``
/// to change what it reads.
///
/// It does not page. A reload reads and compares the whole result, so an app
/// with many rows bounds it with `ListFilters.limit`, and grows the bound by
/// assigning ``reading`` again.
@MainActor @Observable
public final class LiveQuery<Value: Sendable & Equatable> {
    /// The copy the query reads.
    public let copy: WorkingCopy

    /// What the query reads.
    ///
    /// Assigning it starts a new read at once and drops the answer of any read
    /// still running for the old one, even when the new reading equals the old.
    public var reading: Reading<Value> {
        didSet { startRead() }
    }

    /// What the last successful read answered, or the reading's placeholder
    /// before one.
    public private(set) var value: Value

    /// Whether a read is running: from the query's creation until its first read ends, and during every later one.
    ///
    /// A view that shows a spinner for the first load only checks it together
    /// with an empty ``value``.
    public private(set) var isLoading = true

    /// Why the last read failed, and `nil` after a read succeeds.
    ///
    /// ``value`` stays what the last successful read answered, and the next
    /// change reads again.
    public private(set) var error: (any Error)?

    /// Whether the query still hears its copy.
    ///
    /// It says nothing of a failed read; see ``error``.
    public private(set) var following = Following.live

    @ObservationIgnored private var schedule = ReadSchedule()
    @ObservationIgnored private var waiting: [CheckedContinuation<Void, Never>] = []
    nonisolated private let tasks = Tasks()

    public init(_ copy: WorkingCopy, reading: Reading<Value>) {
        self.copy = copy
        self.reading = reading
        value = reading.placeholder
        follow()
    }

    /// Reads now, and returns after a read that began after this call.
    ///
    /// For a query whose ``following`` is `ended` it also asks the copy for a
    /// new stream, which is the app's decision: the core ends a stream on a fault so
    /// that nothing asks again by itself.
    public func refresh() async {
        if case .ended = following { follow() }
        changed()
        guard schedule.running else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Takes a stream and then reads, so a change in between is in the read or told by the stream.
    private func follow() {
        let copy = copy
        following = .live
        let task = Task { @concurrent [weak self] in
            guard !Task.isCancelled else { return }
            // A reader's `changes()` reads the store before it returns.
            let stream = copy.changes()
            await self?.changed()
            for await change in stream {
                guard let query = self else { return }
                await query.heard(change)
            }
            guard !Task.isCancelled else { return }
            await self?.streamFinished()
        }
        tasks.replaceFollow(task)
    }

    private func heard(_ change: Change) {
        switch change.origin {
        case .serverUnreachable, .serverReachable:
            return
        case .stopped(let reason):
            following = .stopped(reason)
            return
        case .server, .refreshed(.hydrated), .refreshed(.caughtUp):
            if case .stopped = following { following = .live }
        default:
            break
        }
        changed()
    }

    private func streamFinished() {
        if case .stopped(let reason) = following {
            following = .ended(reason)
        } else {
            following = .ended(nil)
        }
        finishWaiting()
    }

    private func changed() {
        if schedule.heard() { startRead() }
    }

    private func startRead() {
        let number = schedule.start()
        isLoading = true
        let (reading, copy) = (reading, copy)
        let task = Task { @concurrent [weak self] in
            let result: Result<Value, any Error>
            do {
                result = .success(try await reading.read(copy))
            } catch {
                result = .failure(error)
            }
            await self?.finishRead(number, result)
        }
        tasks.replaceRead(task)
    }

    private func finishRead(_ number: Int, _ result: Result<Value, any Error>) {
        switch schedule.end(number) {
        case .obsolete:
            return
        case .again:
            apply(result)
            startRead()
        case .idle:
            apply(result)
            isLoading = false
            finishWaiting()
        }
    }

    private func apply(_ result: Result<Value, any Error>) {
        switch result {
        case .success(let answer):
            value = answer
            if error != nil { error = nil }
        case .failure(let failure):
            error = failure
        }
    }

    private func finishWaiting() {
        guard !schedule.running else { return }
        for waiter in waiting.drain() { waiter.resume() }
    }
}

/// Which read is the latest, and whether a change came while one ran.
struct ReadSchedule {
    private(set) var current = 0
    private(set) var running = false
    private var changedMeanwhile = false

    enum End {
        /// A newer read took its place, so its answer is dropped.
        case obsolete
        /// A change came while it ran: apply the answer, then read again.
        case again
        case idle
    }

    /// A change was told.
    ///
    /// Returns whether to read now. While a read runs, one more read follows it instead.
    mutating func heard() -> Bool {
        guard running else { return true }
        changedMeanwhile = true
        return false
    }

    /// A read begins, and one still running becomes obsolete.
    ///
    /// Returns the new read's number.
    mutating func start() -> Int {
        current += 1
        running = true
        changedMeanwhile = false
        return current
    }

    mutating func end(_ number: Int) -> End {
        guard running, number == current else { return .obsolete }
        if changedMeanwhile { return .again }
        running = false
        return .idle
    }
}

/// The tasks of one query, held apart from it so its `deinit`, which cannot touch
/// main actor state, can cancel them.
///
/// The tasks hold the query weakly and this not at all, or a task would keep the
/// query alive and `deinit` would never run. Cancelling the stream's task ends
/// its iteration, which takes the stream's place in the core's watch.
private final class Tasks: Sendable {
    private let held = Mutex<(follow: Task<Void, Never>?, read: Task<Void, Never>?)>((nil, nil))

    func replaceFollow(_ task: Task<Void, Never>) {
        held.withLock {
            $0.follow?.cancel()
            $0.follow = task
        }
    }

    func replaceRead(_ task: Task<Void, Never>) {
        held.withLock {
            $0.read?.cancel()
            $0.read = task
        }
    }

    deinit {
        held.withLock {
            $0.follow?.cancel()
            $0.read?.cancel()
        }
    }
}
