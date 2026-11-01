import Foundation
internal import MarfaCore
import Synchronization

/// What a working copy is doing with its server, as ``CopyUpdate/connection`` tells it.
public enum CopyConnection: Sendable, Hashable {
    /// The copy has no server to follow: it was opened without one, or it is a reader, which hears the writer's
    /// saves instead.
    case local
    /// The copy must be hydrated before it can follow its server, for this reason: an error with
    /// ``MarfaError/isHydrationNeeded``, such as `copyExpired` or `instanceChanged`; for a copy that holds no
    /// completed hydration, the error the app's own catch-up or hydration last failed with, such as `wrongServer`;
    /// or `nil` for such a copy before one has failed. Nothing is tried again until a hydration completes.
    case needsHydration(MarfaError?)
    /// The copy is asking its server: as updates begin, after ``WorkingCopy/useKey(_:)``, and while a refill fills
    /// a stale copy again.
    case connecting
    /// The copy reached its server and follows its events.
    case following
    /// The server can't be reached for now, for this error. The copy tries again by itself, further apart each
    /// time, and never sooner than a rate limit asks.
    case offline(MarfaError)
    /// The follow, or the app's own ``WorkingCopy/catchUp()`` or ``WorkingCopy/hydrate(types:tier:edgeTypes:inPlaceOnly:)``,
    /// stopped with an error that asking again may not clear, such as a refusal from the server, a fault in the
    /// store, `noCatalog` or `wrongServer`. The copy tries again every five minutes, in case the server changed, and
    /// follows again only once a catch-up or a hydration succeeds, the app's or the retry's. An error the app's own
    /// arguments caused (`invalid`, `unknownType`, `validation`), a call canceled and a call made during a key
    /// change do not stop it.
    ///
    /// For a reader, the core ended its watch of the writer's saves on a fault. The reader takes it again by itself,
    /// further apart each time, and is `.local` once it has.
    case stopped(MarfaError)
    /// The server refused the copy's key. Nothing is tried again until ``WorkingCopy/useKey(_:)`` gives the copy a
    /// new one.
    case keyRefused(MarfaError)
    /// The copy was closed. It is the last update.
    case closed

    /// Whether the copy follows its server now.
    public var isFollowing: Bool { self == .following }
}

/// How far a hydration has got, as ``CopyUpdate/fill`` tells it while one runs.
public struct FillProgress: Sendable, Hashable {
    /// How many rows the hydration's listings have brought.
    public var listed: UInt64
    /// How many items the slice held on the server when the hydration started; `nil` where the server didn't
    /// count them.
    public var expected: UInt64?

    public init(listed: UInt64, expected: UInt64?) {
        self.listed = listed
        self.expected = expected
    }

    /// `listed` against `expected`, from 0 to 1; `nil` without an `expected` count.
    public var fraction: Double? {
        guard let expected else { return nil }
        guard expected > 0 else { return 1 }
        return min(Double(listed) / Double(expected), 1)
    }
}

/// What to read again after a ``CopyUpdate``.
public enum Reread: Sendable, Hashable {
    /// Read the whole copy again, the type catalog included.
    case everything
    /// Read these parts again; any part not named is unchanged.
    case parts(Parts)

    /// The parts of a copy an update can name.
    public struct Parts: Sendable, Hashable {
        /// The items and edges to read again, each by ID.
        public var rows: ChangedRows
        /// Read ``Queue/all()`` again.
        public var queue: Bool
        /// Read ``Items/views()`` again.
        ///
        /// Set when this copy writes a view; a view another device writes arrives in `rows` under the view's item
        /// ID, as any item does.
        public var views: Bool
        /// Read ``WorkingCopy/catalog`` again.
        public var catalog: Bool

        public init(rows: ChangedRows = ChangedRows(), queue: Bool = false, views: Bool = false, catalog: Bool = false)
        {
            self.rows = rows
            self.queue = queue
            self.views = views
            self.catalog = catalog
        }

        /// Nothing to read again.
        public var isEmpty: Bool { rows.isEmpty && !queue && !views && !catalog }
    }

    /// Nothing to read again: the update only says something else, such as a new ``CopyUpdate/connection``.
    public var isEmpty: Bool {
        switch self {
        case .everything: false
        case .parts(let parts): parts.isEmpty
        }
    }
}

/// One update ``WorkingCopy/updates()`` delivers: what to read again, and the copy's state as the update was made.
public struct CopyUpdate: Sendable, Hashable {
    /// What changed since the update before, to read again.
    public var reread: Reread
    /// What the copy is doing with its server.
    public var connection: CopyConnection
    /// How far a hydration has got while one runs, and `nil` otherwise.
    public var fill: FillProgress?
    /// When the copy last finished a pull from its server, as ``Status/lastSynced`` says.
    public var lastSynced: Date?

    public init(reread: Reread, connection: CopyConnection, fill: FillProgress? = nil, lastSynced: Date? = nil) {
        self.reread = reread
        self.connection = connection
        self.fill = fill
        self.lastSynced = lastSynced
    }
}

/// The updates ``WorkingCopy/updates()`` hands out.
///
/// Iterate it once.
public struct CopyUpdates: AsyncSequence, Sendable {
    public typealias Element = CopyUpdate
    public typealias Failure = Never

    let lifecycle: Lifecycle
    let id: UUID
    let signals: AsyncStream<Void>

    public func makeAsyncIterator() -> Iterator {
        Iterator(lifecycle: lifecycle, id: id, signals: signals.makeAsyncIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        public typealias Element = CopyUpdate
        public typealias Failure = Never

        let lifecycle: Lifecycle
        let id: UUID
        var signals: AsyncStream<Void>.AsyncIterator

        public mutating func next() async -> CopyUpdate? {
            while await signals.next() != nil {
                switch await lifecycle.take(id) {
                case .finished: return nil
                case .nothing: continue
                case .update(let update): return update
                }
            }
            return nil
        }
    }
}

/// Keeps a writer's follow of its server going while ``WorkingCopy/updates()`` is iterated, and turns what the copy
/// tells its streams into updates, each to read again by.
///
/// It holds one stream of the feed, so the core follows the server while any update sequence is held, and hears the
/// copy's own announcements apart from that stream, so they arrive while the core has ended it. The core itself waits
/// out failures of the network and the server while its follow has a stream; what it leaves to its caller, a follow
/// it stopped, a stream it ended on a fault and a drain that left writes undelivered, is tried again here.
final class Lifecycle: Sendable {
    /// How soon the lifecycle tries again, and how often it reads the copy's status.
    struct Pace: Sendable {
        /// The first wait after a failure that may mend itself, doubling up to `most`.
        var first: Duration
        var most: Duration
        /// A follow that ran this long since it last failed starts its waits again from `first`.
        var settle: Duration
        /// The wait after a failure that may not mend itself.
        var slow: Duration
        /// How often a server event reads the copy's status for ``CopyUpdate/lastSynced``.
        var synced: Duration
        /// How often a running hydration's progress is read.
        var progress: Duration

        static let standard = Pace(
            first: .seconds(5), most: .seconds(300), settle: .seconds(300), slow: .seconds(300), synced: .seconds(30),
            progress: .milliseconds(500))
    }

    /// More items or edges named in one update than this are delivered as ``Reread/everything``.
    static let rowLimit = 1_000
    /// The longest wait a rate limit is taken at, against a server that names an absurd one.
    static let longestWait: Duration = .seconds(3600)

    enum Take {
        case finished
        case nothing
        case update(CopyUpdate)
    }

    /// What one consumer has still to be told.
    private struct Pending {
        var everything = false
        var rows = false
        var queue = false
        var views = false
        var catalog = false
        /// Read the copy's status for `lastSynced`.
        var synced = false
    }

    private struct Consumer {
        let signal: AsyncStream<Void>.Continuation
        var pending: Pending
        var cursor: ChangeCursor?
        var told: CopyUpdate?
        var finished = false
        #if DEBUG
        /// Updates a test scripted, each delivered as it was given.
        var scripted: [CopyUpdate] = []
        #endif
    }

    private enum Failure {
        case ignored
        case keyRefused
        case needsHydration
        case offline
        case stopped
    }

    private struct State {
        var consumers: [UUID: Consumer] = [:]
        var connection = CopyConnection.connecting
        var fill: FillProgress?
        var lastSynced: Date?
        var syncedReadAt: Duration?
        var closed = false
        /// At least one consumer is held, so the lifecycle holds a stream of the feed.
        var active = false
        /// Moves each time the lifecycle starts or stops, so a stream of an earlier run is ignored.
        var run = 0
        /// Moves with `run` and with every key change, so a pull or a wait begun before either is ignored.
        var epoch = 0
        /// The stream the lifecycle holds or is taking, so no second one is taken beside it.
        var streamClaim: UUID?
        /// Counts the claimed streams that ended, so a pull can tell whether the stream it found claimed had ended
        /// before the pull began.
        var streamsLetGo = 0
        /// Where the claimed stream ended, its count in `streamsLetGo`; its task may still be reading what the core
        /// told it before.
        var claimLetGo: Int?
        var stream: Task<Void, Never>?
        var retry: Task<Void, Never>?
        var drainRetry: Task<Void, Never>?
        var progress: Task<Void, Never>?
        var attempts = 0
        var drainAttempts = 0
        /// The clock's reading when the copy last began following.
        var followingSince: Duration?
        var keyChanging = false
        /// Hydrations running, the app's and refills alike.
        var fills = 0
        /// Signaled once the lock is let go.
        var signals: [AsyncStream<Void>.Continuation] = []
        var canceled: [Task<Void, Never>] = []
    }

    private let holder: CoreHolder
    private let feed: Feed
    private let hasServer: Bool
    private let pace: Pace
    private let clock: Feed.RefillClock
    private let state = Mutex(State())

    #if DEBUG
    /// Runs after a consumer starts a run and before the run's first step, so a test can hold that moment.
    let started = Mutex<(@Sendable () -> Void)?>(nil)
    #endif

    init(holder: CoreHolder, feed: Feed, hasServer: Bool, pace: Pace, clock: Feed.RefillClock) {
        self.holder = holder
        self.feed = feed
        self.hasServer = hasServer
        self.pace = pace
        self.clock = clock
        feed.observe { [weak self] event in
            switch event {
            case .fillBegan(let byRefill): self?.fillBegan(byRefill: byRefill)
            case .fillEnded: self?.fillEnded()
            case .refillFailed(let error): self?.refillFailed(error)
            case .announced(let change): self?.heard(change)
            }
        }
    }

    /// Runs `body` under the lock, then signals and cancels what it queued, outside the lock.
    private func locked<T: Sendable>(_ body: (inout State) throws -> T) rethrows -> T {
        let (result, signals, canceled) = try state.withLock {
            state -> (T, [AsyncStream<Void>.Continuation], [Task<Void, Never>]) in
            let result = try body(&state)
            return (result, state.signals.drain(), state.canceled.drain())
        }
        for task in canceled { task.cancel() }
        for signal in signals { signal.yield() }
        return result
    }

    // MARK: Consumers

    func updates() -> CopyUpdates {
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in self?.leave(id) }
        let follows = self.follows
        let starts = locked { state -> (run: Int, epoch: Int, claim: UUID?)? in
            state.consumers[id] = Consumer(signal: continuation, pending: Pending(everything: true))
            state.signals.append(continuation)
            guard !state.closed, !state.active else { return nil }
            state.active = true
            state.run += 1
            state.epoch += 1
            // Reset with the run, so no consumer reads the run before's connection.
            state.attempts = 0
            state.drainAttempts = 0
            state.followingSince = nil
            state.connection = follows ? .connecting : .local
            if state.fills > 0 { startProgress(&state) }
            return (state.run, state.epoch, claimStream(&state))
        }
        if let starts {
            #if DEBUG
            started.withLock { $0 }?()
            #endif
            start(run: starts.run, epoch: starts.epoch, claim: starts.claim)
        }
        return CopyUpdates(lifecycle: self, id: id, signals: signals)
    }

    /// What the copy is doing with its server now.
    var connection: CopyConnection { state.withLock { $0.connection } }

    #if DEBUG
    /// Delivers `update` as given to every sequence held now.
    ///
    /// Its connection, fill and `lastSynced` also become what later updates tell until something real changes them,
    /// and a sequence asked for later is told them in its first update. A closed copy ignores it.
    func script(_ update: CopyUpdate) {
        locked { state in
            guard !state.closed else { return }
            state.connection = update.connection
            state.fill = update.fill
            state.lastSynced = update.lastSynced
            for (id, var consumer) in state.consumers where !consumer.finished {
                consumer.scripted.append(update)
                state.signals.append(consumer.signal)
                state.consumers[id] = consumer
            }
        }
    }
    #endif

    private func leave(_ id: UUID) {
        locked { state in
            state.consumers[id] = nil
            guard state.consumers.isEmpty, state.active else { return }
            state.active = false
            state.run += 1
            state.epoch += 1
            stopWork(&state)
        }
    }

    private func stopWork(_ state: inout State) {
        state.canceled += [state.stream, state.retry, state.drainRetry, state.progress].compactMap { $0 }
        state.stream = nil
        state.retry = nil
        state.drainRetry = nil
        state.progress = nil
        state.streamClaim = nil
        state.claimLetGo = nil
    }

    /// The next update for one consumer, read once the lock is let go.
    func take(_ id: UUID) async -> Take {
        enum Claim {
            case finished
            case closed(CopyUpdate)
            case scripted(CopyUpdate)
            case read(Pending, ChangeCursor?, CopyUpdate)
        }
        let claim = locked { state -> Claim in
            guard var consumer = state.consumers[id], !consumer.finished else { return .finished }
            let pending = consumer.pending
            consumer.pending = Pending()
            if state.closed {
                consumer.finished = true
                // Wakes the consumer once more, to end.
                state.signals.append(consumer.signal)
                state.consumers[id] = consumer
                let reread: Reread = consumer.told == nil ? .everything : .parts(Reread.Parts())
                return .closed(CopyUpdate(reread: reread, connection: .closed, lastSynced: state.lastSynced))
            }
            #if DEBUG
            if !consumer.scripted.isEmpty {
                let update = consumer.scripted.removeFirst()
                consumer.told = update
                consumer.pending = pending
                if !consumer.scripted.isEmpty { state.signals.append(consumer.signal) }
                state.consumers[id] = consumer
                return .scripted(update)
            }
            #endif
            state.consumers[id] = consumer
            // What the update tells besides its reread is what held when its marks were claimed: a connection set
            // after them marks the consumer again, so an update never tells a state ahead of the changes it names.
            let told = CopyUpdate(
                reread: .everything, connection: state.connection, fill: state.fill, lastSynced: state.lastSynced)
            return .read(pending, consumer.cursor, told)
        }
        let (pending, cursor, claimed): (Pending, ChangeCursor?, CopyUpdate)
        switch claim {
        case .finished: return .finished
        case .closed(let update), .scripted(let update): return .update(update)
        case .read(let marks, let held, let state): (pending, cursor, claimed) = (marks, held, state)
        }

        var reread = Reread.parts(
            Reread.Parts(queue: pending.queue, views: pending.views, catalog: pending.catalog))
        var next = cursor
        if pending.everything {
            reread = .everything
            next = try? await Self.changes(holder, since: nil, most: 1).next
        } else if pending.rows {
            switch try? await Self.changes(holder, since: cursor, most: Self.rowLimit) {
            case .named(let rows, let after)?:
                if case .parts(var parts) = reread {
                    parts.rows = rows
                    reread = .parts(parts)
                }
                next = after
            case .everything(let after)?:
                reread = .everything
                next = after
            case nil:
                // A copy that is filling or stale names nothing until a hydration completes, which is told as
                // everything.
                reread = .everything
                next = nil
            }
        }
        var synced: Date??
        if pending.synced {
            // A failed read keeps the time already told rather than telling the copy never synced.
            if let status = try? await holder.run({ core in Status(try core.status()) }) {
                synced = .some(status.lastSynced)
            }
        }

        return locked { state -> Take in
            guard var consumer = state.consumers[id], !consumer.finished else { return .finished }
            if let synced { state.lastSynced = synced }
            consumer.cursor = next
            let update = CopyUpdate(
                reread: reread, connection: claimed.connection, fill: claimed.fill,
                lastSynced: synced ?? claimed.lastSynced)
            let told = consumer.told
            if reread.isEmpty, let told, told.connection == update.connection, told.fill == update.fill,
                told.lastSynced == update.lastSynced
            {
                state.consumers[id] = consumer
                return .nothing
            }
            consumer.told = update
            state.consumers[id] = consumer
            return .update(update)
        }
    }

    private static func changes(_ holder: CoreHolder, since cursor: ChangeCursor?, most: Int) async throws
        -> CopyChanges
    {
        try await CopyChanges.read(holder, since: cursor, most: most)
    }

    /// Tells every consumer what `change` asks it to read again, and wakes it.
    private func mark(_ state: inout State, _ change: (inout Pending) -> Void) {
        for (id, var consumer) in state.consumers {
            change(&consumer.pending)
            state.signals.append(consumer.signal)
            state.consumers[id] = consumer
        }
    }

    private func set(_ state: inout State, _ connection: CopyConnection) {
        guard state.connection != connection else { return }
        if connection == .following { state.followingSince = clock.now }
        state.connection = connection
        mark(&state) { _ in }
    }

    // MARK: Running

    private func start(run: Int, epoch: Int, claim: UUID?) {
        if let claim { takeStream(run, claim) }
        guard follows else { return }
        Task { [weak self] in await self?.begin(epoch) }
    }

    /// A writer with a server follows it; a reader, or a copy without a server, has nothing to follow.
    private var follows: Bool { hasServer && holder.handle == .writer }

    /// A reader watches the writer's saves through its stream.
    private var reads: Bool { holder.handle == .reader }

    /// Claims the stream to take, unless one is held or being taken; the claim and the check are one step, so two
    /// successes at once never take two streams.
    ///
    /// A pull that began once the claimed stream had ended, `began` being ``streamsLetGo()`` read before it, takes
    /// the claim from it: that stream's task may not yet have read the stop the core told it, which would otherwise
    /// show the copy stopped, with no stream, after the pull succeeded. A pull that began earlier proves nothing of
    /// the server since that stop.
    private func claimStream(_ state: inout State, began: Int? = nil) -> UUID? {
        if state.streamClaim != nil {
            guard let letGo = state.claimLetGo, let began, letGo <= began else { return nil }
        }
        let claim = UUID()
        state.streamClaim = claim
        state.claimLetGo = nil
        return claim
    }

    /// How many claimed streams have ended, read before a pull begins.
    func streamsLetGo() -> Int { locked { $0.streamsLetGo } }

    /// The stream of `claim` ended, and its place in the feed with it.
    private func letGo(_ claim: UUID) {
        locked { state in
            guard state.streamClaim == claim, state.claimLetGo == nil else { return }
            state.streamsLetGo += 1
            state.claimLetGo = state.streamsLetGo
        }
    }

    /// Holds a stream of the feed under `claim`, so the core follows the server, and hears what the core tells it;
    /// says whether the core gave the stream a place, or will once a key change ends.
    @discardableResult
    private func takeStream(_ run: Int, _ claim: UUID) -> Bool {
        let (stream, continuation) = AsyncStream<Change>.makeStream()
        // Noted before the feed lets the stream go, so a pull that begins once the feed has let it go sees it ended.
        continuation.onTermination = { [feed, weak self] _ in
            self?.letGo(claim)
            feed.remove(claim)
        }
        let task = Task { [weak self] in
            for await change in stream { self?.heard(change, run: run, claim: claim) }
            self?.streamEnded(claim)
        }
        let taken = locked { state -> Bool in
            guard state.active, state.run == run, state.streamClaim == claim else { return false }
            state.stream = task
            return true
        }
        guard taken else {
            task.cancel()
            continuation.finish()
            return false
        }
        return feed.add(continuation, as: claim, announced: false) != nil && feed.holds(claim)
    }

    /// The first step of a run: a copy that holds a completed hydration is caught up, which says whether the
    /// server answers.
    private func begin(_ epoch: Int) async {
        let hydration = try? await holder.run { core in Hydration(try core.status().hydration) }
        switch hydration {
        case .never?, .inProgress?, .expired?:
            locked { state in
                guard state.epoch == epoch else { return }
                set(&state, .needsHydration(nil))
            }
        default:
            await pull(epoch)
        }
    }

    private func pull(_ epoch: Int) async {
        let began = streamsLetGo()
        do {
            _ = try await caughtUp(holder, feed)
            pulled(epoch: epoch, began: began)
        } catch {
            failed(error, epoch: epoch)
        }
    }

    /// A catch-up or a hydration succeeded, so the core follows the server again.
    ///
    /// `epoch` is `nil` for the app's own call; `began` is ``streamsLetGo()`` read before the pull began.
    func pulled(epoch: Int? = nil, began: Int? = nil) {
        let retake = locked { state -> (run: Int, claim: UUID)? in
            guard state.active, !state.closed, !state.keyChanging, epoch == nil || epoch == state.epoch,
                state.connection != .local
            else { return nil }
            if let retry = state.retry { state.canceled.append(retry) }
            state.retry = nil
            set(&state, .following)
            mark(&state) { $0.synced = true }
            return claimStream(&state, began: began).map { (state.run, $0) }
        }
        if let retake { takeStream(retake.run, retake.claim) }
    }

    /// A catch-up, a hydration or the follow failed with `error`.
    ///
    /// The lifecycle is the one place that says the copy is stopped, so the app's own call (`epoch` is `nil`) counts
    /// as the follow does for every error that proves something of the server or the copy: a following copy
    /// becomes `.stopped` with the follow's slow retry, and a copy without a completed hydration becomes
    /// `.needsHydration` with the error. A copy whose key the server refused stays so, and the end of the call or
    /// an error the app's own arguments caused changes nothing. A stop the stream of `claim` told changes nothing
    /// once another stream is claimed: a pull may have succeeded and taken one since the stop was heard.
    func failed(_ error: any Error, epoch: Int? = nil, claim: UUID? = nil) {
        let error = error as? MarfaError ?? .store(message: "\(error)")
        locked { state in
            guard state.active, !state.closed, !state.keyChanging, epoch == nil || epoch == state.epoch,
                claim == nil || state.streamClaim == claim
            else { return }
            guard follows else {
                // Only a reader's watch, ended on a fault, fails here; the app's own calls prove nothing of it.
                guard epoch != nil, reads, Self.failure(error) != .ignored else { return }
                set(&state, .stopped(error))
                scheduleRetake(&state, after: backoff(&state, retryAfter: Self.retryAfter(error)))
                return
            }
            if epoch == nil {
                if Self.causedByCaller(error) { return }
                // A refused key stands until a new one, whatever else a call found.
                if case .keyRefused = state.connection { return }
            }
            switch Self.failure(error) {
            case .ignored:
                return
            case .keyRefused:
                cancelRetry(&state)
                set(&state, .keyRefused(error))
            case .needsHydration:
                cancelRetry(&state)
                set(&state, .needsHydration(error))
            case .offline:
                set(&state, .offline(error))
                schedulePull(&state, after: backoff(&state, retryAfter: Self.retryAfter(error)))
            case .stopped:
                if epoch == nil, case .needsHydration = state.connection {
                    set(&state, .needsHydration(error))
                    return
                }
                set(&state, .stopped(error))
                state.followingSince = nil
                schedulePull(&state, after: max(pace.slow, Self.retryAfter(error)))
            }
        }
    }

    private static func failure(_ error: MarfaError) -> Failure {
        if error.isKeyRefusal { return .keyRefused }
        if error.isHydrationNeeded { return .needsHydration }
        switch error {
        case .canceled, .closed, .keyChanging: return .ignored
        default: return error.isTransient ? .offline : .stopped
        }
    }

    /// An error that says the app's own arguments were wrong, which proves nothing of the server or the copy.
    private static func causedByCaller(_ error: MarfaError) -> Bool {
        switch error {
        case .invalid, .unknownType, .validation: true
        default: false
        }
    }

    private static func retryAfter(_ error: MarfaError) -> Duration {
        guard case .rateLimited(_, _, let seconds?) = error else { return .zero }
        return min(.seconds(seconds), longestWait)
    }

    /// The wait before the next attempt, after a failure that may mend itself.
    private func backoff(_ state: inout State, retryAfter: Duration) -> Duration {
        if let since = state.followingSince, clock.now - since >= pace.settle { state.attempts = 0 }
        state.followingSince = nil
        let wait = min(pace.first * (1 << min(state.attempts, 30)), pace.most)
        state.attempts += 1
        return max(wait, retryAfter)
    }

    private func cancelRetry(_ state: inout State) {
        if let retry = state.retry { state.canceled.append(retry) }
        state.retry = nil
    }

    private func schedulePull(_ state: inout State, after wait: Duration) {
        cancelRetry(&state)
        let epoch = state.epoch
        state.retry = Task { [weak self, clock] in
            do { try await clock.sleep(for: wait) } catch { return }
            guard let self, self.claimRetry(epoch) else { return }
            await self.pull(epoch)
        }
    }

    /// Takes a reader's stream again after `wait`, and shows it `.local` once the core gave it a place.
    private func scheduleRetake(_ state: inout State, after wait: Duration) {
        cancelRetry(&state)
        let (run, epoch) = (state.run, state.epoch)
        state.retry = Task { [weak self, clock] in
            do { try await clock.sleep(for: wait) } catch { return }
            guard let self, let claim = self.claimRetake(epoch), self.takeStream(run, claim) else { return }
            self.locked { state in
                guard state.active, state.run == run, state.streamClaim == claim else { return }
                state.followingSince = clock.now
                set(&state, .local)
                // A save made while no stream was held went unseen.
                mark(&state) { $0.everything = true }
            }
        }
    }

    /// Lets the waiting retry go on, unless a stop or a key change came first; a later success then won't cancel
    /// the pull it runs.
    private func claimRetry(_ epoch: Int) -> Bool {
        locked { state in
            guard state.epoch == epoch, state.active, !state.closed else { return false }
            state.retry = nil
            return true
        }
    }

    /// ``claimRetry(_:)`` for a reader's retake, which also claims the stream it takes.
    private func claimRetake(_ epoch: Int) -> UUID? {
        locked { state in
            guard state.epoch == epoch, state.active, !state.closed else { return nil }
            state.retry = nil
            return claimStream(&state)
        }
    }

    /// What the core told the lifecycle's stream of `run` under `claim`, or, with neither, what the copy announced.
    private func heard(_ change: Change, run: Int? = nil, claim: UUID? = nil) {
        var pulled = false
        var failure: MarfaError?
        var drain: Result<DrainReport, MarfaError>?
        let epoch = locked { state -> Int? in
            guard run == nil || state.run == run, claim == nil || state.streamClaim == claim, state.active else {
                return nil
            }
            switch change.origin {
            case .local, .answered:
                mark(&state) {
                    $0.rows = true
                    $0.queue = true
                }
            case .server:
                let now = clock.now
                let synced = state.syncedReadAt.map { now - $0 >= pace.synced } ?? true
                if synced { state.syncedReadAt = now }
                mark(&state) {
                    $0.rows = true
                    if synced { $0.synced = true }
                }
                reached(&state)
            case .serverReachable:
                reached(&state)
            case .serverUnreachable(let error):
                switch state.connection {
                case .following, .connecting, .offline: set(&state, .offline(error))
                default: break
                }
            case .queueDrained(let report):
                mark(&state) {
                    $0.rows = true
                    $0.queue = true
                }
                drain = .success(report)
            case .queueNotDrained(let error):
                mark(&state) { $0.queue = true }
                drain = .failure(error)
            case .saved:
                mark(&state) { $0.everything = true }
            case .stopped(let error):
                failure = error
            case .refreshed(let refresh):
                switch refresh {
                case .hydrated:
                    mark(&state) { $0.everything = true }
                    pulled = true
                case .unfinished:
                    mark(&state) { $0.everything = true }
                case .caughtUp:
                    mark(&state) {
                        $0.rows = true
                        $0.synced = true
                    }
                case .drained, .withdrawn:
                    mark(&state) {
                        $0.rows = true
                        $0.queue = true
                    }
                case .forgotten:
                    mark(&state) { $0.queue = true }
                case .pinned, .unpinned, .purged, .folderWritten:
                    mark(&state) { $0.rows = true }
                case .viewWritten:
                    mark(&state) { $0.views = true }
                case .catalog:
                    mark(&state) { $0.catalog = true }
                }
            }
            return state.epoch
        }
        guard let epoch else { return }
        if pulled { self.pulled(epoch: epoch) }
        if let failure { failed(failure, epoch: epoch, claim: claim) }
        switch drain {
        case .success(let report): drained(report)
        case .failure(let error): drainFailed(error)
        case nil: break
        }
    }

    /// The core's follow reached the server, which shows it follows only where it was offline or connecting; a
    /// follow that stopped follows again only once a catch-up or a hydration succeeds.
    private func reached(_ state: inout State) {
        switch state.connection {
        case .offline, .connecting: set(&state, .following)
        default: break
        }
    }

    /// The stream ended.
    ///
    /// The copy closed, or the core ended it on a fault after telling it `.stopped`, which scheduled a catch-up
    /// that takes a stream again when it succeeds, or, for a reader, a wait before it takes one again. A stream ended
    /// with no reason told is taken again the same way. A stream that is no longer the one claimed changes nothing.
    private func streamEnded(_ claim: UUID) {
        locked { state in
            guard state.streamClaim == claim else { return }
            state.stream = nil
            state.streamClaim = nil
            guard state.active, !state.closed, !state.keyChanging, state.retry == nil else { return }
            guard follows else {
                if reads { scheduleRetake(&state, after: backoff(&state, retryAfter: .zero)) }
                return
            }
            switch state.connection {
            case .following, .connecting, .offline:
                set(&state, .connecting)
                schedulePull(&state, after: backoff(&state, retryAfter: .zero))
            default:
                return
            }
        }
    }

    // MARK: Draining

    /// A drain, the app's or the follow's, ended with `report`.
    ///
    /// Writes it left undelivered are drained again while the copy follows; a copy that is offline drains them
    /// when its server is back.
    func drained(_ report: DrainReport) {
        locked { state in
            guard state.active, !state.closed, !state.keyChanging, state.connection != .local else { return }
            if let stopped = report.stopped {
                cancelDrain(&state)
                cancelRetry(&state)
                let refusal = MarfaError.unauthorized(
                    code: stopped, message: "The server refused the key the queue was sent with.")
                set(&state, .keyRefused(refusal))
                return
            }
            guard report.undelivered > 0 else {
                state.drainAttempts = 0
                return
            }
            scheduleDrain(&state, retryAfter: report.retryAfterSeconds.map { min(.seconds($0), Self.longestWait) })
        }
    }

    func drainFailed(_ error: any Error) {
        guard let error = error as? MarfaError else { return }
        locked { state in
            guard state.active, !state.closed, !state.keyChanging, state.connection != .local else { return }
            if error.isKeyRefusal {
                cancelDrain(&state)
                cancelRetry(&state)
                set(&state, .keyRefused(error))
            } else if error.isTransient {
                scheduleDrain(&state, retryAfter: Self.retryAfter(error))
            }
        }
    }

    private func cancelDrain(_ state: inout State) {
        if let drain = state.drainRetry { state.canceled.append(drain) }
        state.drainRetry = nil
    }

    private func scheduleDrain(_ state: inout State, retryAfter: Duration?) {
        guard state.connection == .following else { return }
        cancelDrain(&state)
        let wait = max(min(pace.first * (1 << min(state.drainAttempts, 30)), pace.most), retryAfter ?? .zero)
        state.drainAttempts += 1
        let epoch = state.epoch
        state.drainRetry = Task { [weak self, clock, holder, feed] in
            do { try await clock.sleep(for: wait) } catch { return }
            guard let self else { return }
            let runs = self.locked { state -> Bool in
                guard state.epoch == epoch, state.active, !state.closed, state.connection == .following else {
                    return false
                }
                state.drainRetry = nil
                return true
            }
            guard runs else { return }
            do {
                self.drained(try await drainQueue(holder, feed))
            } catch {
                self.drainFailed(error)
            }
        }
    }

    // MARK: Key changes and closing

    func keyWillChange() {
        locked { state in
            state.keyChanging = true
            state.epoch += 1
            cancelRetry(&state)
            cancelDrain(&state)
        }
    }

    /// The key change ended, with the new key or, where it failed, the old one: catch up at once.
    func keyChanged() {
        let epoch = locked { state -> Int? in
            state.keyChanging = false
            guard state.active, !state.closed else { return nil }
            guard follows else {
                set(&state, .local)
                return nil
            }
            state.attempts = 0
            state.drainAttempts = 0
            state.followingSince = nil
            set(&state, .connecting)
            return state.epoch
        }
        guard let epoch else { return }
        Task { [weak self] in await self?.pull(epoch) }
    }

    /// Ends every update sequence with a last update saying `.closed`.
    func close() {
        locked { state in
            guard !state.closed else { return }
            state.closed = true
            state.active = false
            state.run += 1
            state.epoch += 1
            stopWork(&state)
            state.connection = .closed
            mark(&state) { _ in }
        }
    }

    // MARK: Hydration progress

    private func fillBegan(byRefill: Bool) {
        locked { state in
            state.fills += 1
            guard state.active else { return }
            if byRefill {
                switch state.connection {
                case .following, .offline: set(&state, .connecting)
                default: break
                }
            }
            startProgress(&state)
        }
    }

    /// A refill failed for now and waits to try again, so the copy cannot reach its server.
    private func refillFailed(_ error: MarfaError) {
        locked { state in
            guard state.active, !state.closed, !state.keyChanging else { return }
            switch state.connection {
            case .following, .connecting, .offline: set(&state, .offline(error))
            default: break
            }
        }
    }

    private func fillEnded() {
        locked { state in
            state.fills = max(state.fills - 1, 0)
            guard state.fills == 0 else { return }
            if let progress = state.progress { state.canceled.append(progress) }
            state.progress = nil
            guard state.fill != nil else { return }
            state.fill = nil
            mark(&state) { _ in }
        }
    }

    /// Reads the copy's status while a hydration runs, since the core reports its progress nowhere else.
    private func startProgress(_ state: inout State) {
        guard state.progress == nil else { return }
        let run = state.run
        state.progress = Task { [weak self, clock, holder, pace] in
            while !Task.isCancelled {
                if let status = try? await holder.run({ core in try core.status() }) {
                    let progress = FillProgress(listed: status.itemsListed ?? 0, expected: status.itemsExpected)
                    guard let self else { return }
                    let goesOn = self.locked { state -> Bool in
                        guard state.run == run, state.active, state.fills > 0 else { return false }
                        guard progress != state.fill else { return true }
                        // The rows arrive page by page, and a read while the copy fills answers those that have.
                        let arrived = progress.listed != (state.fill?.listed ?? 0)
                        state.fill = progress
                        mark(&state) { if arrived { $0.everything = true } }
                        return true
                    }
                    guard goesOn else { return }
                }
                do { try await clock.sleep(for: pace.progress) } catch { return }
            }
        }
    }
}
