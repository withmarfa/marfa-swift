import Foundation
import MarfaCore
import Synchronization

/// A local copy of a slice of one server, and the queue of writes it holds
/// for that server.
///
/// Every call runs the core off the caller's thread: the core blocks on its
/// store and on the network, and an app's main actor must not.
public final class WorkingCopy: Sendable {
    let core: Core
    let hasServer: Bool
    let reading: Bool
    let observers = Observers()

    public let items: Items
    public let edges: Edges
    public let tags: Tags
    public let metadata: Metadata
    public let extensions: Extensions
    public let blobs: Blobs
    public let queue: Queue

    init(core: Core, hasServer: Bool, reading: Bool) {
        self.core = core
        self.hasServer = hasServer
        self.reading = reading
        items = Items(core: core, observers: observers)
        edges = Edges(core: core, observers: observers)
        tags = Tags(core: core, observers: observers)
        metadata = Metadata(core: core, observers: observers)
        extensions = Extensions(core: core, observers: observers)
        blobs = Blobs(core: core, observers: observers)
        queue = Queue(core: core)
    }

    /// Opens the store at `store`, making it when absent.
    ///
    /// Without a server it reads what it holds and queues writes; with one it
    /// also hydrates, catches up, follows and drains. A second opener of one
    /// store gets a reading handle.
    public static func open(store: URL, server: Server? = nil) async throws -> WorkingCopy {
        let core = try await background {
            try Core.open(path: store.path, url: server?.url.absoluteString, key: server?.key)
        }
        return WorkingCopy(core: core, hasServer: server != nil, reading: false)
    }

    /// Opens a store another process writes, to read it only: it never takes
    /// the writer role, so a helper started first cannot lock the app out,
    /// and it refuses a path where no store has been made.
    public static func openReader(store: URL) async throws -> WorkingCopy {
        let core = try await background { try Core.openReader(path: store.path) }
        return WorkingCopy(core: core, hasServer: false, reading: true)
    }

    /// The writer, or a reader of a store another process writes.
    public var handle: Handle { core.heldHandle() }

    public func status() async throws -> Status {
        try await background { [core] in try core.status() }
    }

    /// Replaces the copy with every item of `types` at `tier`.
    public func hydrate(types: [String], tier: Tier) async throws -> HydrateReport {
        try await background { [core] in try core.hydrate(types: types, tier: tier) }
    }

    /// Applies every event since the last hydration or catch-up.
    public func catchUp() async throws -> CatchUpReport {
        try await background { [core] in try core.catchUp() }
    }

    /// Full-text search over titles, bodies and tags, best match first.
    public func search(_ query: String, filters: SearchFilters = SearchFilters(), limit: Int = 20) async throws
        -> [SearchHit]
    {
        try await background { [core] in
            try core.search(query: query, filters: filters.core, limit: UInt32(clamping: limit)).map(SearchHit.init)
        }
    }

    /// Every change to the copy while the stream is held.
    ///
    /// That is the writes this working copy makes and, where it has a server,
    /// each event the server sends as it lands. A reader is told each time the
    /// writer saves. Ending the iteration stops what feeds it.
    public func changes() -> AsyncStream<Change> {
        AsyncStream { continuation in
            let token = observers.add(continuation)
            if reading {
                let watch = Task { [core] in
                    var seen = try? core.dataVersion()
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard let now = try? core.dataVersion(), now != seen else { continue }
                        seen = now
                        continuation.yield(Change(origin: .saved(dataVersion: now), itemId: nil, edgeId: nil))
                    }
                }
                continuation.onTermination = { [observers] _ in
                    watch.cancel()
                    observers.remove(token)
                }
            } else if hasServer {
                let subscription = core.follow(listener: Listener(continuation))
                continuation.onTermination = { [observers] _ in
                    subscription.stop()
                    observers.remove(token)
                }
            } else {
                continuation.onTermination = { [observers] _ in observers.remove(token) }
            }
        }
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
    }

    public let origin: Origin
    public let itemId: String?
    public let edgeId: String?
}

/// Items: read, and each write queued with its own verdict to come.
public struct Items: Sendable {
    let core: Core
    let observers: Observers

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

    public func create(_ draft: Draft) async throws -> QueuedWrite {
        try await write { core in try core.createItem(draft: draft.core()) }
    }

    public func update(_ id: String, _ edit: Edit) async throws -> QueuedWrite {
        try await write { core in try core.updateItem(id: id, edit: edit.core()) }
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
            observers.announce(write)
        }
        return attached
    }

    private func write(_ work: @escaping @Sendable (Core) throws -> QueuedWrite) async throws -> QueuedWrite {
        let written = try await background { [core] in try work(core) }
        observers.announce(written)
        return written
    }
}

/// Edges between items, each its own write.
public struct Edges: Sendable {
    let core: Core
    let observers: Observers

    /// The edges the copy holds from one item.
    public func from(_ id: String) async throws -> [Edge] {
        try await background { [core] in try core.edgesFrom(id: id).map(Edge.init) }
    }

    public func create(from source: String, to target: String, type: String, properties: [String: JSONValue] = [:])
        async throws -> QueuedWrite
    {
        let draft = CoreEdgeDraft(
            sourceId: source, targetId: target, edgeType: type, propertiesJson: try Properties.text(properties),
            id: nil)
        return try await write { core in try core.createEdge(draft: draft) }
    }

    public func update(_ id: String, properties: [String: JSONValue], baseVersion: Int64) async throws -> QueuedWrite {
        let edit = CoreEdgeEdit(propertiesJson: try Properties.text(properties), baseVersion: baseVersion)
        return try await write { core in try core.updateEdge(id: id, edit: edit) }
    }

    public func delete(_ id: String) async throws -> QueuedWrite {
        try await write { core in try core.deleteEdge(id: id) }
    }

    private func write(_ work: @escaping @Sendable (Core) throws -> QueuedWrite) async throws -> QueuedWrite {
        let written = try await background { [core] in try work(core) }
        observers.announce(written)
        return written
    }
}

/// Tags on an item, one write per tag.
public struct Tags: Sendable {
    let core: Core
    let observers: Observers

    public func add(_ tag: String, to id: String) async throws -> QueuedWrite {
        let written = try await background { [core] in try core.addTag(id: id, tag: tag) }
        observers.announce(written)
        return written
    }

    public func remove(_ tag: String, from id: String) async throws -> QueuedWrite {
        let written = try await background { [core] in try core.removeTag(id: id, tag: tag) }
        observers.announce(written)
        return written
    }
}

/// An item's tags, written whole or merged into what is there.
public struct Metadata: Sendable {
    let core: Core
    let observers: Observers

    public func replaceTags(of id: String, with tags: [String]) async throws -> QueuedWrite {
        let written = try await background { [core] in try core.replaceMetadata(id: id, tags: tags) }
        observers.announce(written)
        return written
    }

    public func mergeTags(_ tags: [String], into id: String) async throws -> QueuedWrite {
        let written = try await background { [core] in try core.mergeMetadata(id: id, tags: tags) }
        observers.announce(written)
        return written
    }
}

/// An item's extension namespaces, each its own write.
public struct Extensions: Sendable {
    let core: Core
    let observers: Observers

    public func write(_ namespace: String, _ body: [String: JSONValue], on id: String) async throws -> QueuedWrite {
        let text = try Properties.text(body)
        let written = try await background { [core] in
            try core.writeExtension(id: id, namespace: namespace, bodyJson: text)
        }
        observers.announce(written)
        return written
    }

    public func delete(_ namespace: String, from id: String) async throws -> QueuedWrite {
        let written = try await background { [core] in try core.deleteExtension(id: id, namespace: namespace) }
        observers.announce(written)
        return written
    }
}

/// Blobs' bytes: uploaded as queued writes, fetched when asked for.
public struct Blobs: Sendable {
    let core: Core
    let observers: Observers

    /// Holds a file's bytes beside the store and queues their upload.
    public func put(file: URL, mimeType: String? = nil) async throws -> QueuedWrite {
        let written = try await background { [core] in try core.putBlob(path: file.path, mimeType: mimeType) }
        observers.announce(written)
        return written
    }

    /// Where a blob's bytes are held, fetched first where they are not.
    ///
    /// With no bytes and no way to fetch them, `MarfaError.BytesAbsent`.
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

    public func all() async throws -> [QueuedWrite] {
        try await background { [core] in try core.queue() }
    }

    /// Sends what the queue holds, once, and records each verdict.
    public func drain() async throws -> DrainReport {
        try await background { [core] in try core.drain() }
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

/// Runs blocking core work on a thread of its own and hands the result back.
func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}

/// The streams told of the writes this working copy makes.
final class Observers: Sendable {
    private let held = Mutex<[UUID: AsyncStream<Change>.Continuation]>([:])

    func add(_ continuation: AsyncStream<Change>.Continuation) -> UUID {
        let token = UUID()
        held.withLock { $0[token] = continuation }
        return token
    }

    func remove(_ token: UUID) {
        _ = held.withLock { $0.removeValue(forKey: token) }
    }

    var count: Int { held.withLock { $0.count } }

    func announce(_ write: QueuedWrite) {
        let change = Change(origin: .local(write.kind), itemId: write.itemId, edgeId: write.edgeId)
        for continuation in held.withLock({ Array($0.values) }) {
            continuation.yield(change)
        }
    }
}

/// What the core tells of each event a held stream applies.
final class Listener: CoreChangeListener, Sendable {
    let continuation: AsyncStream<Change>.Continuation

    init(_ continuation: AsyncStream<Change>.Continuation) {
        self.continuation = continuation
    }

    func changed(change: CoreChange) {
        continuation.yield(
            Change(
                origin: .server(event: change.event, cursor: change.cursor), itemId: change.itemId,
                edgeId: change.edgeId))
    }

    /// The stream ended, stopped or refused: the caller's iteration ends too.
    func ended(error: CoreMarfaError?) {
        continuation.finish()
    }
}
