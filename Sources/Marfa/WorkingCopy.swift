import Foundation
import MarfaCore
import MarfaCoreNames
import Synchronization

/// A local copy of a slice of one server, and the queue of writes it holds
/// for that server.
///
/// Every call that can wait on the store or the network runs the core off
/// the caller's thread, which an app's main actor must never wait on. The one
/// exception is the version a reader's first `changes()` reads before it
/// returns, so that a save made after the call is told; it waits on the
/// connection the copy's other reads share.
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

    init(core: Core, hasServer: Bool) {
        self.core = core
        let source: Feed.Source =
            core.heldHandle() == .reader ? .watch : hasServer ? .follow : .none
        feed = Feed(core: core, source: source)
        items = Items(core: core, feed: feed)
        edges = Edges(core: core, feed: feed)
        tags = Tags(core: core, feed: feed)
        metadata = Metadata(core: core, feed: feed)
        extensions = Extensions(core: core, feed: feed)
        blobs = Blobs(core: core, feed: feed)
        queue = Queue(core: core, feed: feed)
    }

    /// Opens the store at `store`, making it when absent.
    ///
    /// Without a server it reads what it holds and queues writes; with one it
    /// also hydrates, catches up, follows and drains. A second opener of one
    /// store gets a reading handle, and its `changes()` watch for the
    /// writer's saves.
    public static func open(store: URL, server: Server? = nil) async throws -> WorkingCopy {
        let core = try await background {
            try Core.open(path: store.path, url: server?.url.absoluteString, key: server?.key)
        }
        return WorkingCopy(core: core, hasServer: server != nil)
    }

    /// Opens a store another process writes, to read it only: it never takes
    /// the writer role, so a helper started first cannot lock the app out,
    /// and it refuses a path where no store has been made.
    public static func openReader(store: URL) async throws -> WorkingCopy {
        let core = try await background { try Core.openReader(path: store.path) }
        return WorkingCopy(core: core, hasServer: false)
    }

    /// The writer, or a reader of a store another process writes.
    public var handle: Handle { core.heldHandle() }

    public func status() async throws -> Status {
        try await background { [core] in try core.status() }
    }

    /// Replaces the copy with every item of `types` at `tier`.
    ///
    /// The event stream `changes()` holds stops while it runs and starts
    /// again after, from the cursor the hydration stored.
    public func hydrate(types: [String], tier: Tier) async throws -> HydrateReport {
        await feed.pause()
        defer { feed.unpause() }
        let report = try await background { [core] in try core.hydrate(types: types, tier: tier) }
        feed.announce(Change(origin: .refreshed(.hydrated), itemId: nil, edgeId: nil))
        return report
    }

    /// Applies every event since the last hydration or catch-up.
    ///
    /// The event stream `changes()` holds stops while it runs, because the
    /// core lets one stream at a time move the cursor, and starts again
    /// after.
    public func catchUp() async throws -> CatchUpReport {
        await feed.pause()
        defer { feed.unpause() }
        let report = try await background { [core] in try core.catchUp() }
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
    /// Each write this working copy makes, told once by the call that made
    /// it; for a writer with a server, each event its held event stream
    /// applies; for a reader, each save the writer makes once this has
    /// returned; and a hydration, a catch-up that applied events or a drain
    /// that recorded verdicts, after which many rows may differ. One event
    /// stream, or one watch on the store, feeds every stream held, and stops
    /// once none is.
    ///
    /// For a reader this reads where the store stands before it returns, so
    /// a save made straight after it is told rather than taken as where the
    /// watch began.
    ///
    /// Where what feeds them stops with an error, each stream is told with
    /// `.stopped`, as is a stream taken while it stays stopped, and all go
    /// on hearing local writes. A writer's next hydration or catch-up starts
    /// its event stream again; a reader's watch starts again only in a
    /// working copy opened anew. Ending the iteration lets the stream go.
    public func changes() -> AsyncStream<Change> {
        let (stream, continuation) = AsyncStream<Change>.makeStream()
        if let token = feed.add(continuation) {
            continuation.onTermination = { [feed] _ in feed.remove(token) }
        }
        return stream
    }

    /// Ends every stream `changes()` handed out, and returns once what fed
    /// them has stopped.
    ///
    /// A held event stream runs on a thread of the core's that holds the
    /// store, and a writer's claim on it, until it ends. The store is let go
    /// once nothing holds this working copy any more.
    public func close() async {
        await feed.close()
    }
}

/// One change to the copy, and where it came from.
public struct Change: Sendable, Hashable {
    public enum Origin: Sendable, Hashable {
        /// A write this working copy made.
        case local(WriteKind)
        /// An event the server sent, and the cursor it left.
        case server(event: String, cursor: String)
        /// The writer saved; a reader reads again.
        case saved(dataVersion: Int64)
        /// Many rows may have changed at once.
        case refreshed(Refresh)
        /// What fed the stream stopped with this error. Local writes are
        /// still told.
        case stopped(MarfaError)
    }

    public enum Refresh: Sendable, Hashable {
        case hydrated
        case caughtUp
        case drained
    }

    public let origin: Origin
    public let itemId: String?
    public let edgeId: String?
}

/// Items: read, and each write queued with its own verdict to come.
public struct Items: Sendable {
    let core: Core
    let feed: Feed

    public func list(
        _ filters: ListFilters = ListFilters(), sort: Sort = Sort(field: .createdAt, direction: .descending)
    )
        async throws -> [Item]
    {
        try await background { [core] in try core.list(filters: filters.core, sort: sort).map(Item.init) }
    }

    /// One item by id, or nothing where the copy holds none outside the bin.
    public func get(_ id: String) async throws -> Item? {
        try await background { [core] in try core.get(id: id).map(Item.init) }
    }

    /// The thumbnail the item carries, where its type declares one, read from
    /// the held row with no request.
    public func thumbnail(_ id: String) async throws -> Thumbnail? {
        try await background { [core] in try core.thumbnail(id: id) }
    }

    public func create(_ draft: Draft) async throws -> QueuedWrite {
        try await write { core in try core.createItem(draft: draft.core()) }
    }

    /// Queues an edit based on the version the copy holds; one naming any
    /// other version is refused.
    public func update(_ id: String, _ edit: Edit) async throws -> QueuedWrite {
        try await write { core in try core.updateItem(id: id, edit: edit.core()) }
    }

    /// Queues an edit based on a version read before the one the copy holds.
    ///
    /// The server merges it against what was read. An editor that held a row
    /// while the copy caught up saves this way, so what came in meanwhile is
    /// merged rather than overwritten by the values it read. Its next edit
    /// goes on the version held, and it sends only what its person changed.
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
        try await write { core in try core.transitionItem(id: id, state: state) }
    }

    /// Attaches a file to an item: its upload, a file item naming the bytes,
    /// and an `attached-to` edge, each with its own verdict.
    public func attach(to id: String, file: URL, _ attachment: Attachment = Attachment()) async throws -> Attached {
        let attached = try await background { [core] in
            try core.attach(id: id, path: file.path, attachment: attachment)
        }
        for write in [attached.upload, attached.item, attached.edge] {
            feed.announce(write)
        }
        return attached
    }

    private func write(_ work: @escaping @Sendable (Core) throws -> QueuedWrite) async throws -> QueuedWrite {
        let written = try await background { [core] in try work(core) }
        feed.announce(written)
        return written
    }
}

/// Edges between items, each its own write.
public struct Edges: Sendable {
    let core: Core
    let feed: Feed

    /// The edges the copy holds from one item.
    public func from(_ id: String) async throws -> [Edge] {
        try await background { [core] in try core.edgesFrom(id: id).map(Edge.init) }
    }

    /// The edges the copy holds to one item: a thread's replies, the files
    /// attached to it.
    public func to(_ id: String) async throws -> [Edge] {
        try await background { [core] in try core.edgesTo(id: id).map(Edge.init) }
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

    private func write(_ work: @escaping @Sendable (Core) throws -> QueuedWrite) async throws -> QueuedWrite {
        let written = try await background { [core] in try work(core) }
        feed.announce(written)
        return written
    }
}

/// Tags on an item, one write per tag.
public struct Tags: Sendable {
    let core: Core
    let feed: Feed

    public func add(_ tag: String, to id: String) async throws -> QueuedWrite {
        let written = try await background { [core] in try core.addTag(id: id, tag: tag) }
        feed.announce(written)
        return written
    }

    public func remove(_ tag: String, from id: String) async throws -> QueuedWrite {
        let written = try await background { [core] in try core.removeTag(id: id, tag: tag) }
        feed.announce(written)
        return written
    }
}

/// An item's tags, written whole or merged into what is there.
public struct Metadata: Sendable {
    let core: Core
    let feed: Feed

    public func replaceTags(of id: String, with tags: [String]) async throws -> QueuedWrite {
        let written = try await background { [core] in try core.replaceMetadata(id: id, tags: tags) }
        feed.announce(written)
        return written
    }

    public func mergeTags(_ tags: [String], into id: String) async throws -> QueuedWrite {
        let written = try await background { [core] in try core.mergeMetadata(id: id, tags: tags) }
        feed.announce(written)
        return written
    }
}

/// An item's extension namespaces, each its own write.
public struct Extensions: Sendable {
    let core: Core
    let feed: Feed

    public func write(_ namespace: String, _ body: [String: JSONValue], on id: String) async throws -> QueuedWrite {
        let written = try await background { [core] in
            try core.writeExtension(id: id, namespace: namespace, bodyJson: try Properties.text(body))
        }
        feed.announce(written)
        return written
    }

    public func delete(_ namespace: String, from id: String) async throws -> QueuedWrite {
        let written = try await background { [core] in try core.deleteExtension(id: id, namespace: namespace) }
        feed.announce(written)
        return written
    }
}

/// Blobs' bytes: uploaded as queued writes, fetched when asked for.
public struct Blobs: Sendable {
    let core: Core
    let feed: Feed

    /// Holds a file's bytes beside the store and queues their upload.
    public func put(file: URL, mimeType: String? = nil) async throws -> QueuedWrite {
        let written = try await background { [core] in try core.putBlob(path: file.path, mimeType: mimeType) }
        feed.announce(written)
        return written
    }

    /// Where a blob's bytes are held, fetched first where they are not.
    ///
    /// With no bytes and no way to fetch them, `MarfaError.bytesAbsent`.
    public func get(_ hash: String) async throws -> URL {
        URL(fileURLWithPath: try await background { [core] in try core.blob(hash: hash) })
    }

    /// Whether the bytes are held, with no request.
    public func isHeld(_ hash: String) async throws -> Bool {
        try await background { [core] in try core.blobHeld(hash: hash) }
    }
}

/// The writes the copy holds for the server, and what became of each.
public struct Queue: Sendable {
    let core: Core
    let feed: Feed

    public func all() async throws -> [QueuedWrite] {
        try await background { [core] in try core.queue() }
    }

    /// Sends what the queue holds, once, and records each verdict.
    public func drain() async throws -> DrainReport {
        let report = try await background { [core] in try core.drain() }
        if !report.verdicts.isEmpty {
            feed.announce(Change(origin: .refreshed(.drained), itemId: nil, edgeId: nil))
        }
        return report
    }

    /// Sends a blocked or dead write again, under a fresh key.
    public func release(_ id: String) async throws -> Bool {
        try await background { [core] in try core.release(id: id) }
    }

    /// Releases every write blocked for one reason, and says how many.
    public func release(reason: BlockedReason) async throws -> UInt64 {
        try await background { [core] in try core.releaseReason(reason: reason) }
    }

    /// Clears the writes the server has answered, and says how many went.
    public func forgetAnswered() async throws -> UInt64 {
        try await background { [core] in try core.forgetAnswered() }
    }
}

/// Runs blocking core work on a thread of its own and hands the result back,
/// with the core's errors as the package's.
func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try translated(work) })
        }
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

/// The streams `changes()` handed out, and the one source that feeds them.
///
/// That is a held event stream for a writer with a server, and a watch on the
/// store for a reader. One however many streams are held, because the core
/// lets one stream at a time move a store's cursor.
final class Feed: Sendable {
    enum Source {
        case none, follow, watch
    }

    private enum Phase {
        case idle
        case following(generation: Int, CoreSubscription)
        /// Asked to stop and not yet ended. The core lets go of its stream
        /// only as the follow ends, so nothing that takes the stream may
        /// start until then.
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
        /// Moves with every start, so a source that was stopped or replaced
        /// reaches nothing when it speaks late.
        var generation = 0
        /// Hydrations and catch-ups under way, each holding the follow off.
        var pauses = 0
        /// The source ended on its own, and only the next hydration or
        /// catch-up starts it again: a follow ends on what asking again does
        /// not clear.
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

    /// The watch that runs, where one does.
    var watchTask: Task<Void, Never>? {
        state.withLock { state in
            if case .watching(_, let task) = state.phase { task } else { nil }
        }
    }

    /// Holds a stream, and starts the source where it should run and does
    /// not. `nil`, with the stream finished, once the working copy is closed.
    func add(_ continuation: AsyncStream<Change>.Continuation) -> UUID? {
        let token = UUID()
        // Where this stream starts the watch, its version is read before the
        // caller goes on, so a save it makes next moves the version past this
        // one, and outside the lock, since the read can wait on the store.
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
            return (true, state.halted ? state.failure : nil)
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

    /// Stops the follow, returns once it has ended, and holds it off until
    /// `unpause`.
    ///
    /// A watch moves no cursor, so a pause leaves it running.
    func pause() async {
        guard source == .follow else { return }
        state.withLock { state in
            state.pauses += 1
            settle(&state)
        }
        await untilStopped()
    }

    /// Lets the follow start again, and afresh where it had failed.
    func unpause() {
        guard source == .follow else { return }
        state.withLock { state in
            state.pauses -= 1
            state.halted = false
            state.failure = nil
            settle(&state)
        }
    }

    /// Ends every stream, and returns once the source has stopped.
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

    /// Tells `change` while the source of `generation` is the one that
    /// runs, so one stopped or replaced tells nothing.
    func announce(_ change: Change, from generation: Int) {
        let streams = state.withLock { state in
            state.phase.runs(generation) ? Array(state.streams.values) : []
        }
        for continuation in streams { continuation.yield(change) }
    }

    /// The source of `generation` ended: stopped as asked, or on its own
    /// with `error`.
    func ended(generation: Int, error: MarfaError?) {
        typealias Ended = (told: [AsyncStream<Change>.Continuation], waiting: [CheckedContinuation<Void, Never>])
        let ended = state.withLock { state -> Ended in
            switch state.phase {
            case .stopping(let current) where current == generation:
                state.phase = .idle
                let waiting = state.waitingForStop
                state.waitingForStop = []
                settle(&state)
                return ([], waiting)
            case .following(let current, _) where current == generation,
                .watching(let current, _) where current == generation:
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
        for continuation in ended.waiting { continuation.resume() }
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

    /// Starts the source or stops it, to match whether it should run: a
    /// stream held and nothing holding it off.
    ///
    /// A watch starts from `seen`, which only `add` passes, since only a
    /// stream added starts one. It is read here instead where the watch
    /// stopped between `add`'s look and this call.
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
            let seen = seen ?? Result { try translated { try core.dataVersion() } }
            return .watching(
                generation: generation,
                Task { [core] in await self.watch(core, from: seen, generation: generation) })
        }
    }

    private func watch(_ core: Core, from seen: Result<Int64, any Error>, generation: Int) async {
        do {
            var seen = try seen.get()
            while true {
                try await Task.sleep(for: .milliseconds(250))
                let now = try await background { try core.dataVersion() }
                guard now != seen else { continue }
                seen = now
                announce(Change(origin: .saved(dataVersion: now), itemId: nil, edgeId: nil), from: generation)
            }
        } catch is CancellationError {
            return
        } catch {
            ended(generation: generation, error: error as? MarfaError ?? .store(message: "\(error)"))
        }
    }
}

/// What the core tells of each event a held stream applies.
final class Listener: CoreChangeListener, Sendable {
    let feed: Feed
    let generation: Int

    init(feed: Feed, generation: Int) {
        self.feed = feed
        self.generation = generation
    }

    func changed(change: CoreChange) {
        feed.announce(
            Change(
                origin: .server(event: change.event, cursor: change.cursor), itemId: change.itemId,
                edgeId: change.edgeId),
            from: generation)
    }

    func ended(error: CoreMarfaError?) {
        feed.ended(generation: generation, error: error.map(MarfaError.init))
    }
}
