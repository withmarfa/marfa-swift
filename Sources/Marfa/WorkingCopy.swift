import Foundation
import MarfaCore
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
    let holder: CoreHolder
    let feed: Feed

    public let items: Items
    public let edges: Edges
    public let tags: Tags
    public let metadata: Metadata
    public let extensions: Extensions
    public let blobs: Blobs
    public let queue: Queue
    public let catalog: Catalog

    init(holder: CoreHolder, hasServer: Bool) {
        self.holder = holder
        feed = Feed(holder: holder, source: Feed.Source(handle: holder.handle, hasServer: hasServer))
        items = Items(holder: holder, feed: feed)
        edges = Edges(holder: holder, feed: feed)
        tags = Tags(holder: holder, feed: feed)
        metadata = Metadata(holder: holder, feed: feed)
        extensions = Extensions(holder: holder, feed: feed)
        blobs = Blobs(holder: holder, feed: feed)
        queue = Queue(holder: holder, feed: feed)
        catalog = Catalog(holder: holder)
    }

    /// Opens the store at `store`, making it when absent.
    ///
    /// A new store reads and queues writes before its first hydration. A store
    /// whose hydration was interrupted or whose read view expired requires a
    /// completed hydration before reads and writes resume.
    /// A server lets the copy hydrate, catch up and drain
    /// when the app calls them, and lets a held `changes()` follow its
    /// events. A second opener of one store gets a reading handle,
    /// and its `changes()` watch for the writer's saves.
    public static func open(store: URL, server: Server? = nil) async throws -> WorkingCopy {
        let path = store.path
        let key = server?.key
        guard let server else {
            let core = try await background { try Core.open(path: path, url: nil, key: key) }
            return WorkingCopy(holder: CoreHolder(core), hasServer: false)
        }
        let url = server.url.absoluteString
        let core = try await background { try Core.open(path: path, url: url, key: key) }
        let reopen: @Sendable (String) throws -> Core = { key in
            try Core.open(path: path, url: url, key: key)
        }
        return WorkingCopy(holder: CoreHolder(core, reopen: reopen), hasServer: true)
    }

    /// Opens a store another process writes, to read it only.
    ///
    /// It never takes the writer role, so a helper started first cannot lock
    /// the app out, and it refuses a path where no store has been made.
    public static func openReader(store: URL) async throws -> WorkingCopy {
        let core = try await background { try Core.openReader(path: store.path) }
        return WorkingCopy(holder: CoreHolder(core), hasServer: false)
    }

    /// The role the copy holds, which is the last one it held once closed.
    public var handle: Handle { holder.handle }

    public func status() async throws -> Status {
        try await holder.run { core in Status(try core.status()) }
    }

    /// Replaces the copy with every item of `types` at `tier`, with their tags
    /// and the edges going out from them. `edgeTypes` also holds each named
    /// edge type whole, whichever of its endpoints the item slice holds.
    public func hydrate(types: [String], tier: Tier, edgeTypes: [String] = []) async throws -> HydrateReport {
        await feed.pause()
        defer { feed.unpause() }
        let report = HydrateReport(
            try await holder.runUntilCanceled { core, stop in
                try core.hydrateWith(types: types, tier: tier.core, edgeTypes: edgeTypes, stop: stop)
            })
        feed.announce(Change(origin: .refreshed(.hydrated), itemId: nil, edgeId: nil))
        return report
    }

    /// Replaces the app's declared types, each a JSON type definition.
    ///
    /// Offline creates are checked against them before the first hydration.
    /// Hydration registers any the instance lacks and reports refusals.
    public func declareTypes(_ types: [String]) async throws {
        try await holder.run { core in try core.declareTypes(types: types) }
        feed.announce(Change(origin: .refreshed(.catalog), itemId: nil, edgeId: nil))
    }

    /// Reads the declarations stored in this copy, each as normalized JSON.
    public func declaredTypes() async throws -> [String] {
        try await holder.run { core in try core.declaredTypes() }
    }

    /// Reads and holds an item whatever the slice says of it.
    public func pin(_ id: String) async throws -> PinReport {
        let report = PinReport(try await holder.run { core in try core.pin(id: id) })
        feed.announce(Change(origin: .refreshed(.pinned), itemId: id, edgeId: nil))
        return report
    }

    /// Lets an item outside the slice go unless queued writes still need it.
    public func unpin(_ id: String) async throws -> PinReport {
        let report = PinReport(try await holder.run { core in try core.unpin(id: id) })
        feed.announce(Change(origin: .refreshed(.unpinned), itemId: id, edgeId: nil))
        return report
    }

    /// Reads the type catalog again, then applies every event since the
    /// last hydration or catch-up.
    public func catchUp() async throws -> CatchUpReport {
        await feed.pause()
        defer { feed.unpause() }
        // The core commits a new catalog before it applies anything, so a
        // catch-up that then fails has still changed it.
        let (caughtUp, catalogChanged) = try await holder.runUntilCanceled { core, stop in
            let before = try core.status().catalogVersion
            let caughtUp = Result { try translated { CatchUpReport(try core.catchUp(stop: stop)) } }
            let after = try? core.status().catalogVersion
            return (caughtUp, after.map { $0 != before } ?? false)
        }
        if catalogChanged {
            feed.announce(Change(origin: .refreshed(.catalog), itemId: nil, edgeId: nil))
        }
        let report = try caughtUp.get()
        if report.applied > 0 {
            feed.announce(Change(origin: .refreshed(.caughtUp), itemId: nil, edgeId: nil))
        }
        return report
    }

    /// Full-text search over indexed fields and tags, best match first.
    public func search(_ query: String, filters: SearchFilters = SearchFilters(), limit: Int = 20) async throws
        -> [SearchHit]
    {
        try await holder.run { core in
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
    /// and it stays stopped until the app's next hydration or catch-up. On a
    /// store that holds no completed hydration there are no server events
    /// to follow until the next hydration. Local writes and declarations
    /// still notify the writer's streams. `status().hydration` says which.
    /// A reader's watch keeps retrying and tells `.saved` once it reads a
    /// changed SQLite data version.
    public func changes() -> AsyncStream<Change> {
        let (stream, continuation) = AsyncStream<Change>.makeStream()
        // Set before the stream is added: one finished in between would keep
        // a handler set after, and with it the feed and the core.
        let token = UUID()
        continuation.onTermination = { [feed] _ in feed.remove(token) }
        _ = feed.add(continuation, as: token)
        return stream
    }

    /// Ends every stream `changes()` handed out, stops what feeds them, and
    /// releases the store, so another opener of it can take the writer role
    /// once this returns.
    ///
    /// Calls already running finish first, so this takes as long as the
    /// slowest of them. Every call made after it begins, on the copy or any of
    /// its parts (`items`, `queue` and the rest), throws `MarfaError.closed`,
    /// and a call racing `close()` either completes or throws it. Closing a
    /// closed copy does nothing, and a second `close()` made while the first is
    /// running returns only once the store is released.
    public func close() async {
        await feed.close()
        await holder.close()
    }

    /// Gives the copy a new key for its server: the store is closed and
    /// opened again with `key`, and the copy goes on with it.
    ///
    /// The key is held in memory only, as when opening. Held `changes()`
    /// streams keep going: a follow stopped by the old key, such as an
    /// `unauthorized` one, starts again with the new one, and a stream is
    /// told nothing of the change itself, except that a reader's stream added
    /// during it is told one `.saved`, to read again.
    ///
    /// The store cannot be reopened while a call is running, so this waits for
    /// the slowest running call, and from the moment it starts until the new
    /// key is in use every call on the copy, new ones included, throws
    /// `invalid`: ask again. The role the copy holds, `handle`, is taken again,
    /// so it is a reader if another opener took the writer role in between.
    ///
    /// Throws `noServer` for a copy opened without a server, and `closed` for
    /// a closed one, or one closed while this ran. When the store cannot be
    /// opened again the error is thrown and the copy is closed, its streams
    /// ended.
    public func useKey(_ key: String) async throws {
        try holder.checkKeyCanChange()
        try await feed.suspend()
        defer { feed.resume() }
        do {
            try await holder.replace(key: key)
        } catch {
            if holder.isClosed { await feed.close() }
            throw error
        }
        feed.retarget(Feed.Source(handle: holder.handle, hasServer: true))
    }
}

/// One change to the copy, and where it came from.
public struct Change: Sendable, Hashable {
    public enum Origin: Sendable, Hashable {
        case local(WriteKind)
        case server(event: String, cursor: String)
        /// A drain answered this write; `itemId` and `edgeId` name what it
        /// wrote. Told for each write with a verdict, before the drain's
        /// `.refreshed(.drained)`.
        case answered(DrainVerdict)
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
        case pinned
        case unpinned
        /// The app replaced its declarations, or a refresh read a changed
        /// item type or edge type catalog; read `catalog` again.
        case catalog
    }

    public let origin: Origin
    public let itemId: String?
    public let edgeId: String?
    public let reason: String?

    public init(origin: Origin, itemId: String?, edgeId: String?, reason: String? = nil) {
        self.origin = origin
        self.itemId = itemId
        self.edgeId = edgeId
        self.reason = reason
    }
}

public struct Items: Sendable {
    let holder: CoreHolder
    let feed: Feed

    public func list(
        _ filters: ListFilters = ListFilters(), sort: Sort = Sort(field: .createdAt, direction: .descending)
    )
        async throws -> [Item]
    {
        try await holder.run { core in try core.list(filters: filters.core, sort: sort.core).map(Item.init) }
    }

    /// `nil` for an item in the bin or not held.
    public func get(_ id: String) async throws -> Item? {
        try await holder.run { core in try core.get(id: id).map(Item.init) }
    }

    /// Read from the held row, with no request.
    public func thumbnail(_ id: String) async throws -> Thumbnail? {
        try await holder.run { core in try core.thumbnail(id: id).map(Thumbnail.init) }
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
        let attached = try await holder.run { core in
            try Attached(core.attach(id: id, path: file.path, attachment: attachment.core))
        }
        for write in [attached.upload, attached.item, attached.edge] {
            feed.announce(write)
        }
        return attached
    }

    private func write(_ work: @escaping @Sendable (Core) throws -> MarfaCore.QueuedWrite) async throws -> QueuedWrite {
        try await queued(holder, feed, work)
    }
}

public struct Edges: Sendable {
    let holder: CoreHolder
    let feed: Feed

    public func from(_ id: String) async throws -> [Edge] {
        try await holder.run { core in try core.edgesFrom(id: id).map(Edge.init) }
    }

    /// The edges the copy holds to one item, unsent ones included.
    ///
    /// A hydration holds the edges going out from the slice's items, so an
    /// edge from an item outside it is held only when its type was hydrated
    /// whole or the copy pinned its source item.
    public func to(_ id: String) async throws -> [Edge] {
        try await holder.run { core in try core.edgesTo(id: id).map(Edge.init) }
    }

    /// Every edge of one type the copy holds, unsent ones included, oldest
    /// first: edges going out from held items and edge types hydrated whole.
    public func ofType(_ type: String) async throws -> [Edge] {
        try await holder.run { core in try core.edgesOfType(edgeType: type).map(Edge.init) }
    }

    public func create(
        from source: String, to target: String, type: String, properties: [String: JSONValue] = [:],
        id: String? = nil
    ) async throws -> QueuedWrite {
        try await write { core in
            try core.createEdge(
                draft: MarfaCore.EdgeDraft(
                    sourceId: source, targetId: target, edgeType: type,
                    propertiesJson: try Properties.text(properties), id: id))
        }
    }

    public func update(_ id: String, properties: [String: JSONValue], baseVersion: Int64) async throws -> QueuedWrite {
        try await write { core in
            try core.updateEdge(
                id: id,
                edit: MarfaCore.EdgeEdit(propertiesJson: try Properties.text(properties), baseVersion: baseVersion))
        }
    }

    public func delete(_ id: String) async throws -> QueuedWrite {
        try await write { core in try core.deleteEdge(id: id) }
    }

    private func write(_ work: @escaping @Sendable (Core) throws -> MarfaCore.QueuedWrite) async throws -> QueuedWrite {
        try await queued(holder, feed, work)
    }
}

public struct Tags: Sendable {
    let holder: CoreHolder
    let feed: Feed

    public func add(_ tag: String, to id: String) async throws -> QueuedWrite {
        try await queued(holder, feed) { core in try core.addTag(id: id, tag: tag) }
    }

    public func remove(_ tag: String, from id: String) async throws -> QueuedWrite {
        try await queued(holder, feed) { core in try core.removeTag(id: id, tag: tag) }
    }
}

public struct Metadata: Sendable {
    let holder: CoreHolder
    let feed: Feed

    public func replaceTags(of id: String, with tags: [String]) async throws -> QueuedWrite {
        try await queued(holder, feed) { core in try core.replaceMetadata(id: id, tags: tags) }
    }

    public func mergeTags(_ tags: [String], into id: String) async throws -> QueuedWrite {
        try await queued(holder, feed) { core in try core.mergeMetadata(id: id, tags: tags) }
    }
}

public struct Extensions: Sendable {
    let holder: CoreHolder
    let feed: Feed

    public func write(_ namespace: String, _ body: [String: JSONValue], on id: String) async throws -> QueuedWrite {
        try await queued(holder, feed) { core in
            try core.writeExtension(id: id, namespace: namespace, bodyJson: try Properties.text(body))
        }
    }

    public func delete(_ namespace: String, from id: String) async throws -> QueuedWrite {
        try await queued(holder, feed) { core in
            try core.deleteExtension(id: id, namespace: namespace)
        }
    }
}

public struct Blobs: Sendable {
    let holder: CoreHolder
    let feed: Feed

    /// Copies the file's bytes beside the store and queues their upload.
    public func put(file: URL, mimeType: String? = nil) async throws -> QueuedWrite {
        try await queued(holder, feed) { core in
            try core.putBlob(path: file.path, mimeType: mimeType)
        }
    }

    /// Where a blob's bytes are held, fetching them first when they are not.
    ///
    /// A reader, or a copy without a server, throws `bytesAbsent` instead of
    /// fetching.
    public func get(_ hash: String) async throws -> URL {
        URL(fileURLWithPath: try await holder.run { core in try core.blob(hash: hash) })
    }

    public func isHeld(_ hash: String) async throws -> Bool {
        try await holder.run { core in try core.blobHeld(hash: hash) }
    }
}

public struct Queue: Sendable {
    let holder: CoreHolder
    let feed: Feed

    public func all() async throws -> [QueuedWrite] {
        try await holder.run { core in try core.queue().map(QueuedWrite.init) }
    }

    /// Sends what the queue holds once, and records each verdict.
    ///
    /// Nothing drains on its own.
    public func drain() async throws -> DrainReport {
        let report = DrainReport(try await holder.runUntilCanceled { core, stop in try core.drain(stop: stop) })
        for answered in report.verdicts where answered.verdict != nil {
            feed.announce(Change(origin: .answered(answered), itemId: answered.itemId, edgeId: answered.edgeId))
        }
        if !report.verdicts.isEmpty {
            feed.announce(Change(origin: .refreshed(.drained), itemId: nil, edgeId: nil))
        }
        return report
    }

    /// Queues a blocked or dead write to go again, under a fresh key, on the
    /// next drain.
    public func release(_ id: String) async throws -> Bool {
        try await holder.run { core in try core.release(id: id) }
    }

    public func release(reason: BlockedReason) async throws -> UInt64 {
        try await holder.run { core in try core.releaseReason(reason: reason.core) }
    }

    /// Takes a write that can never be sent out of the queue, and puts its
    /// row back to what the server holds.
    ///
    /// Only a write blocked `ancestorUnavailable` or `conflictUnresolved` is
    /// taken; `false` for any other. Writes waiting on it are refused unsent.
    /// It reads the row from the server first, so it needs the server, and
    /// throws `invalid` when the copy moved during the read; ask again.
    public func withdraw(_ id: String) async throws -> Bool {
        let withdrawn = try await holder.run { core in try core.withdraw(id: id) }
        if withdrawn {
            feed.announce(Change(origin: .refreshed(.withdrawn), itemId: nil, edgeId: nil))
        }
        return withdrawn
    }

    /// Clears answered writes, which otherwise stay in the queue with the
    /// server's answer.
    ///
    /// Blocked and dead writes stay until released or withdrawn, as does an
    /// answered write a waiting write depends on, and a refused write that
    /// carried content stays, its `body` readable, until `discard(_:)`.
    public func forgetAnswered() async throws -> UInt64 {
        try await holder.run { core in try core.forgetAnswered() }
    }

    /// Takes a refused write, and the content it carried, out of the queue.
    ///
    /// `false` for a write that is not refused, or that a waiting write
    /// still depends on, and `notFound` for an id the queue does not hold.
    /// The copy's row already shows what the server holds.
    public func discard(_ id: String) async throws -> Bool {
        try await holder.run { core in try core.discard(id: id) }
    }
}

/// Queues one write and tells every held stream of it.
func queued(_ holder: CoreHolder, _ feed: Feed, _ work: @escaping @Sendable (Core) throws -> MarfaCore.QueuedWrite)
    async throws -> QueuedWrite
{
    let written = try await holder.run { try QueuedWrite(work($0)) }
    feed.announce(written)
    return written
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
    } catch let error as MarfaCore.MarfaError {
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

        init(handle: Handle, hasServer: Bool) {
            self = handle == .reader ? .watch : hasServer ? .follow : .none
        }
    }

    private enum Phase {
        case idle
        case following(generation: Int, MarfaCore.Subscription)
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
        var source: Source
        /// Holds every source off, as a key change does while the core is
        /// replaced; a pause holds off only a follow.
        var suspends = 0
        /// Streams added while a key change held the feed off: a reader's
        /// baseline cannot be read until the new core is held.
        var addedWhileSuspended: Set<UUID> = []
        /// Told once the lock is let go.
        var told: [(AsyncStream<Change>.Continuation, Change)] = []
        var waitingForStop: [CheckedContinuation<Void, Never>] = []
    }

    let holder: CoreHolder
    private let state: Mutex<State>

    /// Runs `body` under the lock, then tells what it queued to stream
    /// continuations, outside the lock.
    private func locked<T: Sendable>(_ body: (inout State) throws -> T) rethrows -> T {
        let (result, told) = try state.withLock { state -> (T, [(AsyncStream<Change>.Continuation, Change)]) in
            let result = try body(&state)
            return (result, state.told.drain())
        }
        for (continuation, change) in told { continuation.yield(change) }
        return result
    }

    init(holder: CoreHolder, source: Source) {
        self.holder = holder
        state = Mutex(State(source: source))
    }

    var count: Int { locked { $0.streams.count } }

    var watchTask: Task<Void, Never>? {
        locked { state in
            if case .watching(_, let task) = state.phase { task } else { nil }
        }
    }

    func add(_ continuation: AsyncStream<Change>.Continuation, as token: UUID = UUID()) -> UUID? {
        // Read before the caller goes on, so a save it makes next is told, and
        // outside the lock, since the read can wait on the store.
        let starts = locked { state in
            guard state.source == .watch, case .idle = state.phase else { return false }
            return !state.closed && !state.halted && state.suspends == 0
        }
        let seen = starts ? Result { try holder.with { try $0.dataVersion() } } : nil
        let (added, failure) = locked { state -> (Bool, MarfaError?) in
            guard !state.closed else { return (false, nil) }
            state.streams[token] = continuation
            if state.suspends > 0 { state.addedWhileSuspended.insert(token) }
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
        locked { state in
            state.streams.removeValue(forKey: token)
            state.addedWhileSuspended.remove(token)
            settle(&state)
        }
    }

    /// A watch moves no cursor, so a pause leaves it running.
    func pause() async {
        locked { state in
            state.pauses += 1
            settle(&state)
        }
        await untilStopped()
    }

    func unpause() {
        locked { state in
            state.pauses -= 1
            if state.source == .follow {
                state.halted = false
                state.failure = nil
            }
            settle(&state)
        }
    }

    /// Stops whatever feeds the streams, whichever source, until `resume()`.
    ///
    /// The streams stay held. Throws `closed` once the feed is.
    func suspend() async throws {
        let refused = locked { state -> Bool in
            guard !state.closed else { return true }
            state.suspends += 1
            settle(&state)
            return false
        }
        if refused { throw MarfaError.closed(message: CoreHolder.closedMessage) }
        await untilStopped()
    }

    func resume() {
        locked { state in
            state.suspends -= 1
            if state.suspends == 0 { state.addedWhileSuspended = [] }
            if state.source == .follow {
                state.halted = false
                state.failure = nil
            }
            settle(&state)
        }
    }

    /// For the core's role changing under a suspended feed.
    ///
    /// A reader's stream added meanwhile could take no baseline, and a save
    /// since may have gone unseen, so each is told one `.saved` to read again.
    func retarget(_ source: Source) {
        let late = locked { state -> [AsyncStream<Change>.Continuation] in
            state.source = source
            state.halted = false
            state.failure = nil
            let late = source == .watch ? state.addedWhileSuspended.compactMap { state.streams[$0] } : []
            state.addedWhileSuspended = []
            settle(&state)
            return late
        }
        guard !late.isEmpty, let now = try? holder.with({ try $0.dataVersion() }) else { return }
        for continuation in late {
            continuation.yield(Change(origin: .saved(dataVersion: now), itemId: nil, edgeId: nil))
        }
    }

    func close() async {
        let (streams, watch) = locked { state in
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
        for continuation in locked({ Array($0.streams.values) }) {
            continuation.yield(change)
        }
    }

    func announce(_ change: Change, from generation: Int) {
        let streams = locked { state in
            state.phase.runs(generation) ? Array(state.streams.values) : []
        }
        for continuation in streams { continuation.yield(change) }
    }

    /// Returns the waiters for the caller to resume outside the lock.
    func ended(generation: Int, error: MarfaError?) -> [CheckedContinuation<Void, Never>] {
        typealias Ended = (told: [AsyncStream<Change>.Continuation], waiting: [CheckedContinuation<Void, Never>])
        let ended = locked { state -> Ended in
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
                // A store that holds no hydration has nothing to follow
                // yet: the streams wait, and the next hydration starts it.
                let told = error.flatMap { Self.awaitsHydration($0) ? nil : $0 }
                state.failure = told
                return (told == nil ? [] : Array(state.streams.values), [])
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

    private static func awaitsHydration(_ error: MarfaError) -> Bool {
        switch error {
        case .hydrationIncomplete, .noCursor: true
        default: false
        }
    }

    private func untilStopped() async {
        await withCheckedContinuation { continuation in
            let stopped = locked { state -> Bool in
                guard case .stopping = state.phase else { return true }
                state.waitingForStop.append(continuation)
                return false
            }
            if stopped { continuation.resume() }
        }
    }

    private func settle(_ state: inout State, seen: Result<Int64, any Error>? = nil) {
        let wanted =
            state.source != .none && !state.streams.isEmpty && !state.halted && !state.closed
            && state.suspends == 0 && (state.source == .watch || state.pauses == 0)
        switch state.phase {
        case .idle where wanted:
            state.generation += 1
            do {
                state.phase = try start(state, generation: state.generation, seen: seen)
            } catch {
                // Stays stopped, as a follow that ended on an error does, until
                // the next hydration or catch-up.
                let error = error as? MarfaError ?? .store(message: "\(error)")
                state.halted = true
                state.failure = error
                let stopped = Change(origin: .stopped(error), itemId: nil, edgeId: nil)
                state.told += state.streams.values.map { ($0, stopped) }
            }
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

    private func start(_ state: State, generation: Int, seen: Result<Int64, any Error>?) throws -> Phase {
        switch state.source {
        case .none:
            return .idle
        case .follow:
            let subscription = try holder.with {
                $0.follow(listener: Listener(feed: self, generation: generation))
            }
            return .following(generation: generation, subscription)
        case .watch:
            // Read under the lock where the watch stopped between `add`'s look
            // and this call.
            let seen = seen ?? Result { try holder.with { try $0.dataVersion() } }
            return .watching(
                generation: generation,
                Task { await self.watch(from: seen, generation: generation) })
        }
    }

    static let watchInterval = Duration.milliseconds(250)
    static let longestWatchRetry = Duration.seconds(2)

    private func watch(from first: Result<Int64, any Error>, generation: Int) async {
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
                read = .success(try await holder.run { try $0.dataVersion() })
            } catch is CancellationError {
                return
            } catch {
                read = .failure(error)
            }
        }
    }

    private func failed(generation: Int, error: MarfaError) {
        let streams = locked { state -> [AsyncStream<Change>.Continuation] in
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
        let streams = locked { state -> [AsyncStream<Change>.Continuation] in
            guard state.phase.runs(generation) else { return [] }
            state.failure = nil
            return Array(state.streams.values)
        }
        for continuation in streams { continuation.yield(change) }
    }
}

/// Weak on the feed, which holds the core holder and with it the writer's claim on
/// the store: the core's thread holds the listener until `ended` returns.
final class Listener: MarfaCore.ChangeListener, Sendable {
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

    func changed(change: MarfaCore.Change) {
        let origin: Change.Origin =
            change.event == Self.catalogChanged
            ? .refreshed(.catalog) : .server(event: change.event, cursor: change.cursor)
        feed?.announce(
            Change(origin: origin, itemId: change.itemId, edgeId: change.edgeId, reason: change.reason),
            from: generation)
    }

    /// What the core names a stream that read a changed catalog, in place of
    /// an event's type.
    static let catalogChanged = "catalog.changed"

    /// Resumes waiters only once nothing on this thread holds the feed, since
    /// one may drop the working copy and open the store again at once.
    func ended(error: MarfaCore.MarfaError?) {
        for continuation in stop(error) { continuation.resume() }
    }

    private func stop(_ error: MarfaCore.MarfaError?) -> [CheckedContinuation<Void, Never>] {
        feed?.ended(generation: generation, error: error.map(MarfaError.init)) ?? []
    }
}
