import Foundation
import MarfaCore
import MarfaCoreNames
import Synchronization

/// A local copy of a slice of one server, and the queue of writes it holds
/// for that server.
///
/// Nothing runs on its own: the app decides when to hydrate, catch up,
/// drain and `forgetAnswered()`. Every call that can wait on the store or the
/// network runs off the caller's thread, except a reader's first
/// `changes()`, which reads the store before it returns and so can wait
/// behind the copy's other reads.
public final class WorkingCopy: Sendable {
    let core: Core
    let feed: Feed

    public let items: Items
    public let edges: Edges
    public let tags: Tags
    public let metadata: Metadata
    public let extensions: Extensions
    public let blobs: Blobs
    public let queue: Queue
    public let catalog: Catalog

    init(core: Core, hasServer: Bool) {
        self.core = core
        let source: Feed.Source =
            Handle(core.heldHandle()) == .reader ? .watch : hasServer ? .follow : .none
        feed = Feed(core: core, source: source)
        items = Items(core: core, feed: feed)
        edges = Edges(core: core, feed: feed)
        tags = Tags(core: core, feed: feed)
        metadata = Metadata(core: core, feed: feed)
        extensions = Extensions(core: core, feed: feed)
        blobs = Blobs(core: core, feed: feed)
        queue = Queue(core: core, feed: feed)
        catalog = Catalog(core: core)
    }

    /// Opens the store at `store`, making it when absent.
    ///
    /// Reads of items and edges, and every write, are refused until the store
    /// holds a completed hydration; after that a copy without a server reads
    /// and queues writes. A server lets the copy hydrate, catch up and drain
    /// when the app calls them, and lets a held `changes()` follow its
    /// events. A second opener of one store gets a reading handle,
    /// and its `changes()` watch for the writer's saves.
    public static func open(store: URL, server: Server? = nil) async throws -> WorkingCopy {
        let core = try await background {
            try Core.open(path: store.path, url: server?.url.absoluteString, key: server?.key)
        }
        return WorkingCopy(core: core, hasServer: server != nil)
    }

    /// Opens a store another process writes, to read it only.
    ///
    /// It never takes the writer role, so a helper started first cannot lock
    /// the app out, and it refuses a path where no store has been made.
    public static func openReader(store: URL) async throws -> WorkingCopy {
        let core = try await background { try Core.openReader(path: store.path) }
        return WorkingCopy(core: core, hasServer: false)
    }

    public var handle: Handle { Handle(core.heldHandle()) }

    public func status() async throws -> Status {
        try await background { [core] in Status(try core.status()) }
    }

    /// Replaces the copy with every item of `types` at `tier`, with their tags
    /// and the edges going out from them.
    public func hydrate(types: [String], tier: Tier) async throws -> HydrateReport {
        await feed.pause()
        defer { feed.unpause() }
        let report = HydrateReport(
            try await background { [core] in try core.hydrate(types: types, tier: tier.core) })
        feed.announce(Change(origin: .refreshed(.hydrated), itemId: nil, edgeId: nil))
        return report
    }

    /// Reads the type catalog again, then applies every event since the
    /// last hydration or catch-up.
    public func catchUp() async throws -> CatchUpReport {
        await feed.pause()
        defer { feed.unpause() }
        let (report, catalogChanged) = try await background { [core] in
            let before = try core.status().catalogVersion
            let report = CatchUpReport(try core.catchUp())
            return (report, try core.status().catalogVersion != before)
        }
        if catalogChanged {
            feed.announce(Change(origin: .refreshed(.catalog), itemId: nil, edgeId: nil))
        }
        if report.applied > 0 {
            feed.announce(Change(origin: .refreshed(.caughtUp), itemId: nil, edgeId: nil))
        }
        return report
    }

    /// Full-text search over titles, bodies and tags, best match first.
    public func search(_ query: String, filters: SearchFilters = SearchFilters(), limit: Int = 20) async throws
        -> [SearchHit]
    {
        try await background { [core] in
            try core.search(query: query, filters: filters.core, limit: UInt32(clamping: limit)).map(SearchHit.init)
        }
    }

    /// What changes in the copy while the stream is held, to read again by.
    ///
    /// A server event the copy applied arrives as `.server`, naming the
    /// event's type and the item or edge it was about. A catch-up or a held
    /// stream that read a changed type catalog arrives as
    /// `.refreshed(.catalog)`, naming neither.
    ///
    /// A writer with a server follows the server's events only while at least
    /// one stream is held, and pauses the follow during a hydration or
    /// catch-up. A reader is told each save the writer makes.
    ///
    /// When the follow stops with an error, every stream is told `.stopped`
    /// and it stays stopped until the app's next hydration or catch-up. A
    /// reader's watch keeps retrying, and tells `.saved` once it reads the
    /// store again.
    public func changes() -> AsyncStream<Change> {
        let (stream, continuation) = AsyncStream<Change>.makeStream()
        // Set before the stream is added: one finished in between would keep
        // a handler set after, and with it the feed and the core.
        let token = UUID()
        continuation.onTermination = { [feed] _ in feed.remove(token) }
        _ = feed.add(continuation, as: token)
        return stream
    }

    /// Ends every stream `changes()` handed out, and returns once what fed
    /// them has stopped.
    ///
    /// It does not release the store. The writer role is released only once
    /// nothing holds this working copy or any of its parts (`items`, `queue`
    /// and the rest), and calls made through them after `close()` still run.
    public func close() async {
        await feed.close()
    }
}

/// One change to the copy, and where it came from.
public struct Change: Sendable, Hashable {
    public enum Origin: Sendable, Hashable {
        case local(WriteKind)
        case server(event: String, cursor: String)
        /// The writer saved; a reader should read again.
        case saved(dataVersion: Int64)
        /// Many rows may have changed at once.
        case refreshed(Refresh)
        /// What fed the stream stopped with this error. Local writes are
        /// still told.
        case stopped(MarfaError)
    }

    public enum Refresh: Sendable, Hashable {
        /// Everything may have changed, the type catalog included.
        case hydrated
        case caughtUp
        case drained
        case withdrawn
        /// A catch-up or a held stream read an item type or edge type
        /// catalog that differs from the one the copy held; read `catalog`
        /// again.
        case catalog
    }

    public let origin: Origin
    public let itemId: String?
    public let edgeId: String?
}

public struct Items: Sendable {
    let core: Core
    let feed: Feed

    public func list(
        _ filters: ListFilters = ListFilters(), sort: Sort = Sort(field: .createdAt, direction: .descending)
    )
        async throws -> [Item]
    {
        try await background { [core] in try core.list(filters: filters.core, sort: sort.core).map(Item.init) }
    }

    /// `nil` for an item in the bin or not held.
    public func get(_ id: String) async throws -> Item? {
        try await background { [core] in try core.get(id: id).map(Item.init) }
    }

    /// Read from the held row, with no request.
    public func thumbnail(_ id: String) async throws -> Thumbnail? {
        try await background { [core] in try core.thumbnail(id: id).map(Thumbnail.init) }
    }

    public func create(_ draft: Draft) async throws -> QueuedWrite {
        try await write { core in try core.createItem(draft: draft.core()) }
    }

    /// Refused unless `edit.baseVersion` is the version the copy holds.
    public func update(_ id: String, _ edit: Edit) async throws -> QueuedWrite {
        try await write { core in try core.updateItem(id: id, edit: edit.core()) }
    }

    /// Queues an edit based on a version older than the one the copy holds.
    ///
    /// The server merges it against what was read. An editor that held a row
    /// while the copy caught up saves this way.
    public func updateAsRead(_ id: String, _ edit: Edit) async throws -> QueuedWrite {
        try await write { core in try core.updateItemAsRead(id: id, edit: edit.core()) }
    }

    /// Moves an item to the bin, and queues the delete.
    public func delete(_ id: String) async throws -> QueuedWrite {
        try await write { core in try core.deleteItem(id: id) }
    }

    public func restore(_ id: String) async throws -> QueuedWrite {
        try await write { core in try core.restoreItem(id: id) }
    }

    public func transition(_ id: String, to state: ItemState) async throws -> QueuedWrite {
        try await write { core in try core.transitionItem(id: id, state: state.core) }
    }

    /// Queues three writes, each with its own verdict: the upload, a file item
    /// naming the bytes, and an `attached-to` edge from the file to the item.
    public func attach(to id: String, file: URL, _ attachment: Attachment = Attachment()) async throws -> Attached {
        let attached = try await background { [core] in
            Attached(try core.attach(id: id, path: file.path, attachment: attachment.core))
        }
        for write in [attached.upload, attached.item, attached.edge] {
            feed.announce(write)
        }
        return attached
    }

    private func write(_ work: @escaping @Sendable (Core) throws -> CoreQueuedWrite) async throws -> QueuedWrite {
        let written = QueuedWrite(try await background { [core] in try work(core) })
        feed.announce(written)
        return written
    }
}

public struct Edges: Sendable {
    let core: Core
    let feed: Feed

    public func from(_ id: String) async throws -> [Edge] {
        try await background { [core] in try core.edgesFrom(id: id).map(Edge.init) }
    }

    /// The edges the copy holds to one item, unsent ones included.
    ///
    /// A hydration holds the edges going out from the slice's items, so an
    /// edge from an item of a type outside the slice, such as a file attached
    /// on another device when `core.file` is not hydrated, is not here.
    public func to(_ id: String) async throws -> [Edge] {
        try await background { [core] in try core.edgesTo(id: id).map(Edge.init) }
    }

    /// Every edge of one type the copy holds, unsent ones included, oldest
    /// first: only edges going out from held items, as with `to(_:)`.
    public func ofType(_ type: String) async throws -> [Edge] {
        try await background { [core] in try core.edgesOfType(edgeType: type).map(Edge.init) }
    }

    public func create(
        from source: String, to target: String, type: String, properties: [String: JSONValue] = [:],
        id: String? = nil
    ) async throws -> QueuedWrite {
        try await write { core in
            try core.createEdge(
                draft: CoreEdgeDraft(
                    sourceId: source, targetId: target, edgeType: type,
                    propertiesJson: try Properties.text(properties), id: id))
        }
    }

    public func update(_ id: String, properties: [String: JSONValue], baseVersion: Int64) async throws -> QueuedWrite {
        try await write { core in
            try core.updateEdge(
                id: id, edit: CoreEdgeEdit(propertiesJson: try Properties.text(properties), baseVersion: baseVersion))
        }
    }

    public func delete(_ id: String) async throws -> QueuedWrite {
        try await write { core in try core.deleteEdge(id: id) }
    }

    private func write(_ work: @escaping @Sendable (Core) throws -> CoreQueuedWrite) async throws -> QueuedWrite {
        let written = QueuedWrite(try await background { [core] in try work(core) })
        feed.announce(written)
        return written
    }
}

public struct Tags: Sendable {
    let core: Core
    let feed: Feed

    public func add(_ tag: String, to id: String) async throws -> QueuedWrite {
        let written = QueuedWrite(try await background { [core] in try core.addTag(id: id, tag: tag) })
        feed.announce(written)
        return written
    }

    public func remove(_ tag: String, from id: String) async throws -> QueuedWrite {
        let written = QueuedWrite(try await background { [core] in try core.removeTag(id: id, tag: tag) })
        feed.announce(written)
        return written
    }
}

public struct Metadata: Sendable {
    let core: Core
    let feed: Feed

    public func replaceTags(of id: String, with tags: [String]) async throws -> QueuedWrite {
        let written = QueuedWrite(try await background { [core] in try core.replaceMetadata(id: id, tags: tags) })
        feed.announce(written)
        return written
    }

    public func mergeTags(_ tags: [String], into id: String) async throws -> QueuedWrite {
        let written = QueuedWrite(try await background { [core] in try core.mergeMetadata(id: id, tags: tags) })
        feed.announce(written)
        return written
    }
}

public struct Extensions: Sendable {
    let core: Core
    let feed: Feed

    public func write(_ namespace: String, _ body: [String: JSONValue], on id: String) async throws -> QueuedWrite {
        let written = QueuedWrite(
            try await background { [core] in
                try core.writeExtension(id: id, namespace: namespace, bodyJson: try Properties.text(body))
            })
        feed.announce(written)
        return written
    }

    public func delete(_ namespace: String, from id: String) async throws -> QueuedWrite {
        let written = QueuedWrite(
            try await background { [core] in try core.deleteExtension(id: id, namespace: namespace) })
        feed.announce(written)
        return written
    }
}

public struct Blobs: Sendable {
    let core: Core
    let feed: Feed

    /// Copies the file's bytes beside the store and queues their upload.
    public func put(file: URL, mimeType: String? = nil) async throws -> QueuedWrite {
        let written = QueuedWrite(
            try await background { [core] in try core.putBlob(path: file.path, mimeType: mimeType) })
        feed.announce(written)
        return written
    }

    /// Where a blob's bytes are held, fetching them first when they are not.
    ///
    /// A reader, or a copy without a server, throws `bytesAbsent` instead of
    /// fetching.
    public func get(_ hash: String) async throws -> URL {
        URL(fileURLWithPath: try await background { [core] in try core.blob(hash: hash) })
    }

    public func isHeld(_ hash: String) async throws -> Bool {
        try await background { [core] in try core.blobHeld(hash: hash) }
    }
}

public struct Queue: Sendable {
    let core: Core
    let feed: Feed

    public func all() async throws -> [QueuedWrite] {
        try await background { [core] in try core.queue().map(QueuedWrite.init) }
    }

    /// Sends what the queue holds once, and records each verdict.
    ///
    /// Nothing drains on its own.
    public func drain() async throws -> DrainReport {
        let report = DrainReport(try await background { [core] in try core.drain() })
        if !report.verdicts.isEmpty {
            feed.announce(Change(origin: .refreshed(.drained), itemId: nil, edgeId: nil))
        }
        return report
    }

    /// Queues a blocked or dead write to go again, under a fresh key, on the
    /// next drain.
    public func release(_ id: String) async throws -> Bool {
        try await background { [core] in try core.release(id: id) }
    }

    public func release(reason: BlockedReason) async throws -> UInt64 {
        try await background { [core] in try core.releaseReason(reason: reason.core) }
    }

    /// Takes a write that can never be sent out of the queue, and puts its
    /// row back to what the server holds.
    ///
    /// Only a write blocked `ancestorUnavailable` or `conflictUnresolved` is
    /// taken; `false` for any other. Writes waiting on it are refused unsent.
    /// It reads the row from the server first, so it needs the server, and
    /// throws `invalid` when the copy moved during the read; ask again.
    public func withdraw(_ id: String) async throws -> Bool {
        let withdrawn = try await background { [core] in try core.withdraw(id: id) }
        if withdrawn {
            feed.announce(Change(origin: .refreshed(.withdrawn), itemId: nil, edgeId: nil))
        }
        return withdrawn
    }

    /// Clears answered writes, which otherwise stay in the queue with the
    /// server's answer.
    ///
    /// Blocked and dead writes stay until released or withdrawn, as does an
    /// answered write a waiting write depends on.
    public func forgetAnswered() async throws -> UInt64 {
        try await background { [core] in try core.forgetAnswered() }
    }
}

func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    let job = Job(work)
    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: job.run())
        }
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

func translated<T>(_ work: () throws -> T) throws -> T {
    do {
        return try work()
    } catch let error as CoreMarfaError {
        throw MarfaError(error)
    } catch let error as DecodingError {
        throw MarfaError.decoding(message: "\(error)")
    } catch EncodingError.invalidValue(_, let context) {
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        throw MarfaError.invalid(message: "\(path) cannot be written as JSON: \(context.debugDescription)")
    }
}

/// One source for however many streams are held, because the core lets one
/// stream at a time move a store's cursor.
final class Feed: Sendable {
    enum Source {
        case none, follow, watch
    }

    private enum Phase {
        case idle
        case following(generation: Int, CoreSubscription)
        /// The core lets go of its stream only as the follow ends, so nothing
        /// that takes the stream may start until then.
        case stopping(generation: Int)
        case watching(generation: Int, Task<Void, Never>)

        func runs(_ generation: Int) -> Bool {
            switch self {
            case .idle: false
            case .following(let current, _), .stopping(let current), .watching(let current, _):
                current == generation
            }
        }
    }

    private struct State {
        var streams: [UUID: AsyncStream<Change>.Continuation] = [:]
        var phase = Phase.idle
        /// A source that was stopped or replaced may still speak late.
        var generation = 0
        var pauses = 0
        /// Only the next hydration or catch-up restarts a follow that ended
        /// on its own: it ended on something asking again does not clear.
        var halted = false
        var failure: MarfaError?
        var closed = false
        var waitingForStop: [CheckedContinuation<Void, Never>] = []
    }

    let core: Core
    let source: Source
    private let state = Mutex(State())

    init(core: Core, source: Source) {
        self.core = core
        self.source = source
    }

    var count: Int { state.withLock { $0.streams.count } }

    var watchTask: Task<Void, Never>? {
        state.withLock { state in
            if case .watching(_, let task) = state.phase { task } else { nil }
        }
    }

    func add(_ continuation: AsyncStream<Change>.Continuation, as token: UUID = UUID()) -> UUID? {
        // Read before the caller goes on, so a save it makes next is told, and
        // outside the lock, since the read can wait on the store.
        let starts =
            source == .watch
            && state.withLock { state in
                guard case .idle = state.phase else { return false }
                return !state.closed && !state.halted
            }
        let seen = starts ? Result { try translated { try core.dataVersion() } } : nil
        let (added, failure) = state.withLock { state -> (Bool, MarfaError?) in
            guard !state.closed else { return (false, nil) }
            state.streams[token] = continuation
            settle(&state, seen: seen)
            return (true, state.failure)
        }
        guard added else {
            continuation.finish()
            return nil
        }
        if let failure {
            continuation.yield(Change(origin: .stopped(failure), itemId: nil, edgeId: nil))
        }
        return token
    }

    func remove(_ token: UUID) {
        state.withLock { state in
            state.streams.removeValue(forKey: token)
            settle(&state)
        }
    }

    /// A watch moves no cursor, so a pause leaves it running.
    func pause() async {
        guard source == .follow else { return }
        state.withLock { state in
            state.pauses += 1
            settle(&state)
        }
        await untilStopped()
    }

    func unpause() {
        guard source == .follow else { return }
        state.withLock { state in
            state.pauses -= 1
            state.halted = false
            state.failure = nil
            settle(&state)
        }
    }

    func close() async {
        let (streams, watch) = state.withLock { state in
            state.closed = true
            var watch: Task<Void, Never>?
            if case .watching(_, let task) = state.phase { watch = task }
            settle(&state)
            let streams = Array(state.streams.values)
            state.streams = [:]
            return (streams, watch)
        }
        for continuation in streams { continuation.finish() }
        await untilStopped()
        await watch?.value
    }

    func announce(_ write: QueuedWrite) {
        announce(Change(origin: .local(write.kind), itemId: write.itemId, edgeId: write.edgeId))
    }

    func announce(_ change: Change) {
        for continuation in state.withLock({ Array($0.streams.values) }) {
            continuation.yield(change)
        }
    }

    func announce(_ change: Change, from generation: Int) {
        let streams = state.withLock { state in
            state.phase.runs(generation) ? Array(state.streams.values) : []
        }
        for continuation in streams { continuation.yield(change) }
    }

    /// Returns the waiters for the caller to resume outside the lock.
    func ended(generation: Int, error: MarfaError?) -> [CheckedContinuation<Void, Never>] {
        typealias Ended = (told: [AsyncStream<Change>.Continuation], waiting: [CheckedContinuation<Void, Never>])
        let ended = state.withLock { state -> Ended in
            switch state.phase {
            case .stopping(let current) where current == generation:
                state.phase = .idle
                let waiting = state.waitingForStop
                state.waitingForStop = []
                settle(&state)
                return ([], waiting)
            case .following(let current, _) where current == generation:
                state.phase = .idle
                state.halted = true
                state.failure = error
                return (error == nil ? [] : Array(state.streams.values), [])
            default:
                return ([], [])
            }
        }
        if let error {
            for continuation in ended.told {
                continuation.yield(Change(origin: .stopped(error), itemId: nil, edgeId: nil))
            }
        }
        return ended.waiting
    }

    private func untilStopped() async {
        await withCheckedContinuation { continuation in
            let stopped = state.withLock { state -> Bool in
                guard case .stopping = state.phase else { return true }
                state.waitingForStop.append(continuation)
                return false
            }
            if stopped { continuation.resume() }
        }
    }

    private func settle(_ state: inout State, seen: Result<Int64, any Error>? = nil) {
        let wanted =
            source != .none && !state.streams.isEmpty && state.pauses == 0 && !state.halted && !state.closed
        switch state.phase {
        case .idle where wanted:
            state.generation += 1
            state.phase = start(generation: state.generation, seen: seen)
        case .following(let generation, let subscription) where !wanted:
            subscription.stop()
            state.phase = .stopping(generation: generation)
        case .watching(_, let task) where !wanted:
            task.cancel()
            state.phase = .idle
            state.failure = nil
        default:
            break
        }
    }

    private func start(generation: Int, seen: Result<Int64, any Error>?) -> Phase {
        switch source {
        case .none:
            return .idle
        case .follow:
            return .following(
                generation: generation, core.follow(listener: Listener(feed: self, generation: generation)))
        case .watch:
            // Read under the lock where the watch stopped between `add`'s look
            // and this call.
            let seen = seen ?? Result { try translated { try core.dataVersion() } }
            return .watching(
                generation: generation,
                Task { [core] in await self.watch(core, from: seen, generation: generation) })
        }
    }

    static let watchInterval = Duration.milliseconds(250)
    static let longestWatchRetry = Duration.seconds(2)

    private func watch(_ core: Core, from first: Result<Int64, any Error>, generation: Int) async {
        var read = first
        var seen: Int64?
        var failing = false
        var wait = Self.watchInterval
        while true {
            switch read {
            case .success(let now):
                let saved = Change(origin: .saved(dataVersion: now), itemId: nil, edgeId: nil)
                if failing {
                    recovered(generation: generation, telling: saved)
                } else if seen.map({ now != $0 }) == true {
                    announce(saved, from: generation)
                }
                seen = now
                failing = false
                wait = Self.watchInterval
            case .failure(let error):
                if !failing {
                    failing = true
                    failed(generation: generation, error: error as? MarfaError ?? .store(message: "\(error)"))
                }
                wait = min(wait * 2, Self.longestWatchRetry)
            }
            do {
                try await Task.sleep(for: wait)
                read = .success(try await background { try core.dataVersion() })
            } catch is CancellationError {
                return
            } catch {
                read = .failure(error)
            }
        }
    }

    private func failed(generation: Int, error: MarfaError) {
        let streams = state.withLock { state -> [AsyncStream<Change>.Continuation] in
            guard state.phase.runs(generation) else { return [] }
            state.failure = error
            return Array(state.streams.values)
        }
        for continuation in streams {
            continuation.yield(Change(origin: .stopped(error), itemId: nil, edgeId: nil))
        }
    }

    /// Clears the failure under the lock that takes the streams, so a stream
    /// added in between is not left told only `.stopped`.
    private func recovered(generation: Int, telling change: Change) {
        let streams = state.withLock { state -> [AsyncStream<Change>.Continuation] in
            guard state.phase.runs(generation) else { return [] }
            state.failure = nil
            return Array(state.streams.values)
        }
        for continuation in streams { continuation.yield(change) }
    }
}

/// Weak on the feed, which holds the core and with it the writer's claim on
/// the store: the core's thread holds the listener until `ended` returns.
final class Listener: CoreChangeListener, Sendable {
    private struct Weak {
        weak var feed: Feed?
    }

    private let held: Mutex<Weak>
    let generation: Int

    init(feed: Feed, generation: Int) {
        held = Mutex(Weak(feed: feed))
        self.generation = generation
    }

    private var feed: Feed? { held.withLock { $0.feed } }

    func changed(change: CoreChange) {
        let origin: Change.Origin =
            change.event == Self.catalogChanged
            ? .refreshed(.catalog) : .server(event: change.event, cursor: change.cursor)
        feed?.announce(Change(origin: origin, itemId: change.itemId, edgeId: change.edgeId), from: generation)
    }

    /// What the core names a stream that read a changed catalog, in place of
    /// an event's type.
    static let catalogChanged = "catalog.changed"

    /// Resumes waiters only once nothing on this thread holds the feed, since
    /// one may drop the working copy and open the store again at once.
    func ended(error: CoreMarfaError?) {
        for continuation in stop(error) { continuation.resume() }
    }

    private func stop(_ error: CoreMarfaError?) -> [CheckedContinuation<Void, Never>] {
        feed?.ended(generation: generation, error: error.map(MarfaError.init)) ?? []
    }
}
