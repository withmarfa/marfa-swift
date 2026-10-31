import Foundation
import Observation
import Synchronization

/// What a ``LiveQuery`` reads from its working copy, and what it shows until
/// the first read ends.
///
/// ``list(_:sort:)``, ``search(_:filters:limit:)``, ``item(_:)``, ``queue`` and
/// the view reads ``views``, ``view(_:)``, ``list(inView:limit:offset:)``
/// and ``groups(inView:timeZone:)`` cover the common reads. `init(placeholder:_:)` makes any other, such as
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

extension Reading where Value == Rows<Item> {
    /// The items `filters` select, as `items.list(_:sort:)` answers them.
    ///
    /// `filters.limit` and `filters.offset` bound the result.
    public static func list(_ filters: ListFilters = ListFilters(), sort: Sort? = nil) -> Reading {
        Reading(placeholder: .unread) { copy in
            try await copy.items.list(filters, sort: sort)
        }
    }

    /// The items a full-text search finds, best match first, as `search(_:filters:limit:)` answers it.
    ///
    /// Without a `limit` the result holds the copy's default number of hits.
    public static func search(_ text: String, filters: SearchFilters = SearchFilters(), limit: Int? = nil) -> Reading {
        Reading(placeholder: .unread) { copy in
            let hits =
                if let limit {
                    try await copy.search(text, filters: filters, limit: limit)
                } else {
                    try await copy.search(text, filters: filters)
                }
            return Rows(hits.map(\.item), completeness: hits.completeness)
        }
    }
}

extension Reading where Value == Item? {
    /// One item, `nil` while the copy does not hold it or it is in the bin, as `items.get(_:)` answers.
    ///
    /// While a hydration fills the copy, an item not held yet fails the read with `hydrationIncomplete`, which the
    /// query's `error` reports.
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

/// Rows, or one item, read from a working copy and read again whenever the copy
/// changes, for a view to show.
///
/// Reading a property in a SwiftUI view's `body` is all a view does to stay
/// current. The query holds one ``WorkingCopy/updates()`` sequence of its copy and
/// reads again after each update that names something to read again, including a
/// local write made offline. A burst of changes causes the read in flight and at
/// most one more, and the result of a read made obsolete by a newer one is
/// dropped. Releasing the query releases its sequence, and with the copy's last
/// sequence the follow of its server.
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

    /// What the copy is doing with its server, as the latest update said.
    ///
    /// It says nothing of a failed read; see ``error``. It is `.connecting` until the first update arrives.
    public private(set) var connection = CopyConnection.connecting

    @ObservationIgnored private var schedule = ReadSchedule()
    @ObservationIgnored private var waiting: [CheckedContinuation<Void, Never>] = []
    nonisolated private let tasks = Tasks()

    /// Reads `copy` as `reading` says, and keeps reading as the copy changes until the query is released.
    public init(_ copy: WorkingCopy, reading: Reading<Value>) {
        self.copy = copy
        self.reading = reading
        value = reading.placeholder
        follow()
    }

    /// Reads now, and returns after a read that began after this call.
    public func refresh() async {
        changed()
        guard schedule.running else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Holds a sequence of updates, whose first update asks for the first read.
    private func follow() {
        let updates = copy.updates()
        let task = Task { @concurrent [weak self] in
            for await update in updates {
                guard let query = self else { return }
                await query.heard(update)
            }
        }
        tasks.replaceFollow(task)
    }

    private func heard(_ update: CopyUpdate) {
        if connection != update.connection { connection = update.connection }
        if !update.reread.isEmpty { changed() }
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
/// query alive and `deinit` would never run. Cancelling the follow's task ends
/// its iteration, which releases its sequence of updates.
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
