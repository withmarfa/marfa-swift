import Foundation
import MarfaCore
import Synchronization

/// A local copy of a slice of one server, and the queue of writes it holds
/// for that server.
///
/// The app decides when to hydrate, catch up, drain and `forgetAnswered()`;
/// only a held `changes()` stream drains on its own, once when its server is
/// back and once after a drain left a write undelivered. Every call that can
/// wait on the store or the network runs off the caller's thread, except a
/// reader's `changes()`, which reads the store before it returns and so can
/// wait behind the copy's other reads.
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

    init(holder: CoreHolder, hasServer: Bool, refillPace: Feed.RefillPace = .standard) {
        self.holder = holder
        feed = Feed(holder: holder, watched: hasServer || holder.handle == .reader, refillPace: refillPace)
        items = Items(holder: holder, feed: feed)
        edges = Edges(holder: holder, feed: feed)
        tags = Tags(holder: holder, feed: feed)
        metadata = Metadata(holder: holder, feed: feed)
        extensions = Extensions(holder: holder, feed: feed)
        blobs = Blobs(holder: holder, feed: feed)
        queue = Queue(holder: holder, feed: feed)
        catalog = Catalog(holder: holder)
    }

    /// A copy over a core that is not the Rust one, for `MarfaTesting`.
    package convenience init(core: any CoreProtocol) {
        self.init(holder: CoreHolder(core, stops: false), hasServer: false)
    }

    package func announce(_ change: Change) {
        feed.announce(change)
    }

    /// Opens the store at `store`, making it when absent.
    ///
    /// A new store reads and queues writes before its first hydration. A store
    /// whose hydration was interrupted or whose reach expired requires a
    /// completed hydration before reads and writes resume.
    /// A server lets the copy hydrate, catch up and drain
    /// when the app calls them, and lets a held `changes()` follow its
    /// events. A second opener of one store gets a reading handle,
    /// and its `changes()` watch for the writer's saves.
    ///
    /// Throws `MarfaError.store` when the store's lock file exists but cannot
    /// be opened for writing, rather than opening a copy that holds a lock it
    /// cannot keep. Throws `SignInError.notSignedIn` for a server made from a
    /// credential whose sign-in the keychain no longer holds. Throws
    /// `MarfaError.wrongSchema` for a store another build of the core made,
    /// and leaves the store as it is: its `unsent` counts the writes the
    /// server has not taken, which only that build can send.
    ///
    /// `fileBudget` chooses the budget of the cache of fetched files, as ``Blobs/setBudget(_:)`` does, trimming to
    /// it before this returns; left `nil`, the copy keeps the choice its store holds, which is the default
    /// budget for a new store. A second opener of a store is a reader and cannot set it: opening with a
    /// `fileBudget` then throws `readingHandle`, and the store is released.
    public static func open(store: URL, server: Server? = nil, fileBudget: FileBudget? = nil) async throws
        -> WorkingCopy
    {
        try await opened(store: store, server: server, fileBudget: fileBudget, replacing: false)
    }

    /// Replaces a store that ``open(store:server:fileBudget:)`` refuses with `wrongSchema` by an empty one of this
    /// build's shape, and opens it, taking its arguments as `open` does.
    ///
    /// The files the copy downloaded stay, because they are kept by content and not by the store. What only the
    /// old store held does not: pins, the position in the server's events, the declared types and the choice of
    /// file budget, which is the default again unless `fileBudget` sets it. Read what matters before replacing,
    /// and hydrate the new copy as you would a new one.
    ///
    /// Leaves the store as it is and throws `wrongSchema`, with its `unsent` count, while it holds a write the
    /// server has not taken, and `readingHandle` while another process writes it. Throws `invalid` for a store
    /// that opens as it is, or a path that holds none.
    public static func replaceRefused(store: URL, server: Server? = nil, fileBudget: FileBudget? = nil) async throws
        -> WorkingCopy
    {
        try await opened(store: store, server: server, fileBudget: fileBudget, replacing: true)
    }

    private static func opened(store: URL, server: Server?, fileBudget: FileBudget?, replacing: Bool) async throws
        -> WorkingCopy
    {
        let path = store.path
        let copy: WorkingCopy
        if let server {
            let url = server.url.absoluteString
            let credential = server.credential
            let core = try await background {
                let renewer = credential.map(TokenRenewer.init)
                let key = try server.openingToken()
                return replacing
                    ? try Core.replaceRefused(path: path, url: url, key: key, renewer: renewer)
                    : try Core.open(path: path, url: url, key: key, renewer: renewer)
            }
            // A key the app switches to replaces the credential, so the reopened copy has nothing to renew.
            let reopen: @Sendable (String) throws -> any CoreProtocol = { key in
                try Core.open(path: path, url: url, key: key)
            }
            copy = WorkingCopy(holder: CoreHolder(core, reopen: reopen), hasServer: true)
        } else {
            let core = try await background {
                replacing
                    ? try Core.replaceRefused(path: path, url: nil, key: nil)
                    : try Core.open(path: path, url: nil, key: nil)
            }
            copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        }
        if let fileBudget {
            do {
                _ = try await copy.blobs.setBudget(fileBudget)
            } catch {
                await copy.close()
                throw error
            }
        }
        return copy
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

    /// Replaces the copy with every item of `types` at `tier`, one tier or
    /// `.all` for both, with their tags and the edges going out from them.
    /// `edgeTypes` also holds each named edge type whole, whichever of its
    /// endpoints the item slice holds.
    ///
    /// `["*"]` alone is every type but `system.*`, hydrated in one pass with no need to read the catalog and name
    /// its types first. Beside `system.*` types it adds them, and beside any other type it throws `invalid`.
    ///
    /// While the call runs, `status()` says how far it has got in `itemsListed` against `itemsExpected`, and a
    /// list or search answers the rows that have arrived, marked `.partial`. A hydration that was interrupted
    /// carries on from the page it reached when its slice is unchanged; the report says whether it did
    /// (`resumed`) or why it started again (`restarted`).
    ///
    /// A copy whose cursor the server's event log let go (`status().hydration` is `.stale`) is filled again over the
    /// rows it holds, which reads answer meanwhile marked `.stale`, and the report says `inPlace`. Until a fill
    /// completes, writes to items (file items and attaches included) are queued, to a row the copy holds or a new
    /// one, and edge writes throw `hydrationIncomplete`.
    ///
    /// The call announces `.refreshed(.hydrated)` when it completes, and `.refreshed(.unfinished)` when it fails or
    /// is canceled, because the rows it wrote stay.
    public func hydrate(types: [String], tier: SliceTier, edgeTypes: [String] = []) async throws -> HydrateReport {
        HydrateReport(try await feed.hydrate(types: types, tier: tier.core, edgeTypes: edgeTypes))
    }

    /// Replaces the app's declared types, each a type definition.
    ///
    /// Offline creates are checked against them before the first hydration.
    /// Hydration registers any the instance lacks and reports refusals.
    public func declareTypes(_ types: [JSONObject]) async throws {
        try await holder.run { core in try core.declareTypes(types: types) }
        feed.announce(Change(origin: .refreshed(.catalog), itemId: nil, edgeId: nil))
    }

    /// Reads the declarations stored in this copy, each with the empty `fields` and the `version` a
    /// registration needs filled in where the app left them out.
    public func declaredTypes() async throws -> [JSONObject] {
        try await holder.run { core in try core.declaredTypes() }
    }

    /// Reads and holds an item whatever the slice says of it.
    ///
    /// An item in the bin is not pinned: it throws `notFound` with the code
    /// `trashed`, so the app can offer to restore it. One the server does not
    /// hold throws `notFound` with the code `not_found`.
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
        // The core commits a new catalog before it applies anything, so a
        // catch-up that then fails has still changed it, and says so.
        let (caughtUp, catalogChanged) = try await holder.runUntilCanceled { core, stop in
            do {
                let report = try core.catchUp(stop: stop)
                return (Result<CatchUpReport, MarfaError>.success(CatchUpReport(report)), report.catalogChanged)
            } catch MarfaCore.CatchUpError.Failed(let error, let catalogChanged) {
                return (.failure(MarfaError(error)), catalogChanged)
            }
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
    ///
    /// While a hydration fills the copy the hits are those of the rows that have arrived, and `completeness` says
    /// `.partial`.
    public func search(_ query: String, filters: SearchFilters = SearchFilters(), limit: Int = 20) async throws
        -> Rows<SearchHit>
    {
        try await holder.run { core in
            try core.search(query: query, filters: filters, limit: UInt32(clamping: limit)).answer
        }
    }

    /// What changes in the copy while the stream is held, to read again by.
    ///
    /// A server event the copy applied arrives as `.server`, naming the
    /// event's type and the item or edge it was about. A catch-up or a held
    /// stream that read a changed type catalog arrives as
    /// `.refreshed(.catalog)`, naming neither.
    ///
    /// The copy says what became of the server: `.serverUnreachable` with
    /// the failure when the follow cannot have its stream, and
    /// `.serverReachable` as soon as a request reaches the server again: the
    /// follow's, a hydration's or catch-up's that succeeded, or a drain's that
    /// answered a write. Each is told once for each change, however often the
    /// follow starts again, and a stream added while the server is
    /// unreachable is told so first. A copy that reaches its server at once
    /// says neither.
    ///
    /// A held stream drains the writes queued meanwhile once, when its follow
    /// next has its stream after the server was lost or after a drain left a
    /// write undelivered, even one the app started or one from an earlier launch.
    /// The app has nothing to start on `.serverReachable`. The drain ends in
    /// `.queueDrained` with its report, or in `.queueNotDrained` with why it
    /// stopped, and the answers it had recorded stay recorded. For
    /// `.queueDrained`, each write with a verdict is told as `.answered`, as
    /// for a drain the app starts. A `.queueNotDrained` error carries no
    /// per-write notifications; read the queue for answers recorded before
    /// the error. A copy opened without a server, and a reader, drain nothing.
    ///
    /// A writer with a server follows the server's events only while at least
    /// one stream is held. A hydration or catch-up takes the stream for its
    /// duration and gives it back, and no stream is told of the gap. A reader
    /// is told each save the writer makes.
    ///
    /// When the server's event log has let the copy's cursor go, as it can
    /// while a Mac sleeps, `status().hydration` is `.stale` and the copy fills
    /// itself again over the slice it holds, as `hydrate` does, telling the
    /// streams `.refreshed(.hydrated)`, and the follow carries on. An attempt
    /// the network or the server fails is told `.refreshed(.unfinished)` and
    /// tried again, at once the first time and then further apart, up to five
    /// minutes. When the follow stops with any other error, or the server
    /// refuses the refill, every stream is told `.stopped` and it stays stopped
    /// until the app's next hydration or catch-up, or until a stream is asked
    /// for while none is held. On a
    /// store that holds no completed hydration the follow waits, asking the
    /// server nothing, until one completes. Local writes and declarations
    /// still notify the writer's streams. `status().hydration` says which.
    /// A reader keeps reading and tells `.saved` once it reads a changed
    /// SQLite data version. A stream the core's own fault ended is told
    /// `.stopped` and then finishes, as one the core refused does: ask for a new
    /// one.
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
        do {
            try await holder.replace(key: key)
        } catch {
            if holder.isClosed { await feed.close() }
            feed.resume(readsOnly: false)
            throw error
        }
        feed.resume(readsOnly: holder.handle == .reader)
    }
}

extension DrainReport {
    /// What a drain tells a held stream: each write it answered, then that rows
    /// may have changed.
    func changes() -> [Change] {
        var told = verdicts.filter { $0.verdict != nil }.map {
            Change(origin: .answered($0), itemId: $0.itemId, edgeId: $0.edgeId)
        }
        if !verdicts.isEmpty { told.append(Change(origin: .refreshed(.drained), itemId: nil, edgeId: nil)) }
        return told
    }
}

/// One change to the copy, and where it came from.
public struct Change: Sendable, Hashable {
    public enum Origin: Sendable, Hashable {
        case local(WriteKind)
        case server(event: String, cursor: String)
        /// The follow cannot have its stream, for this failure: the network,
        /// a rate limit, a failing server, or a refusal naming no contract.
        /// It keeps asking, at a falling rate, and is told once however many
        /// attempts fail.
        case serverUnreachable(MarfaError)
        /// A request reached the server after `.serverUnreachable`: the follow
        /// has its stream, or a hydration, catch-up or drain was answered. A held
        /// stream whose follow has its stream drains the queue now, and tells
        /// how it ended.
        case serverReachable
        /// The drain the follow ran when the server came back ended, and this
        /// is what it did. Told after the `.answered` and `.refreshed(.drained)`
        /// of the writes it answered.
        case queueDrained(DrainReport)
        /// The drain the follow ran when the server came back stopped with
        /// this error. The answers it had recorded stay recorded, and the
        /// writes it did not reach stay queued for the next drain.
        case queueNotDrained(MarfaError)
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
        /// A hydration failed or was canceled part way. The rows it wrote stay, so a reader should read again, and
        /// nothing about the copy's follow is learned from it.
        case unfinished
        case caughtUp
        case drained
        case withdrawn
        /// Answered or refused writes left the queue, through `forgetAnswered()`,
        /// `forgetAnswered(ids:)` or `discard(_:)`; read the queue again.
        case forgotten
        case pinned
        case unpinned
        /// An item, named by `itemId`, was purged and left the copy.
        case purged
        /// A folder's settings, named by `itemId`, were created, changed or
        /// revoked; the copy holds the answer where its slice or a pin takes it,
        /// and otherwise at its next catch-up.
        case folderWritten
        /// A view, named by `itemId`, was created or changed; the copy holds the answer where its slice or a pin
        /// takes it, and otherwise at its next catch-up. A deleted view is told as `.purged`.
        case viewWritten
        /// The app replaced its declarations, or a refresh read a changed
        /// item type or edge type catalog; read `catalog` again.
        case catalog
    }

    public let origin: Origin
    public let itemId: String?
    public let edgeId: String?

    public init(origin: Origin, itemId: String?, edgeId: String?) {
        self.origin = origin
        self.itemId = itemId
        self.edgeId = edgeId
    }
}

public struct Items: Sendable {
    let holder: CoreHolder
    let feed: Feed

    /// The items `filters` select.
    ///
    /// While a hydration fills the copy the list holds the rows that have arrived, and `completeness` says
    /// `.partial`.
    public func list(
        _ filters: ListFilters = ListFilters(), sort: Sort = Sort(field: .createdAt, direction: .descending)
    )
        async throws -> Rows<Item>
    {
        try await holder.run { core in try core.list(filters: filters, sort: sort.core).answer }
    }

    /// `nil` for an item in the bin or not held.
    ///
    /// While a hydration fills the copy, an item not held yet may still arrive, so asking for it throws
    /// `hydrationIncomplete` rather than answering `nil`.
    public func get(_ id: String) async throws -> Item? {
        try await holder.run { core in try core.get(id: id) }
    }

    /// The ID of the item a conflicted copy was made from: the item its
    /// `derived-from` edge points to.
    ///
    /// `nil` unless `id` is a held item, outside the bin, tagged
    /// `conflicted-copy` and linked. The original may be an item the copy
    /// doesn't hold.
    public func original(ofConflictedCopy id: String) async throws -> String? {
        try await holder.run { core in try core.originalOfConflictedCopy(id: id) }
    }

    /// The held conflicted copies made from an item.
    ///
    /// Copies in the bin are left out. Oldest link first. The item itself need
    /// not be held.
    public func conflictedCopies(of id: String) async throws -> [Item] {
        try await holder.run { core in try core.conflictedCopiesOf(id: id) }
    }

    /// Read from the held row, with no request.
    public func thumbnail(_ id: String) async throws -> Thumbnail? {
        try await holder.run { core in try core.thumbnail(id: id).map(Thumbnail.init) }
    }

    public func create(_ draft: Draft) async throws -> QueuedWrite {
        try await write { core in try core.createItem(draft: draft) }
    }

    /// Refused unless `edit.baseVersion` is the version the copy holds.
    public func update(_ id: String, _ edit: Edit) async throws -> QueuedWrite {
        try await write { core in try core.updateItem(id: id, edit: edit) }
    }

    /// Queues an edit based on a version older than the one the copy holds.
    ///
    /// The server merges it against what was read. An editor that held a row
    /// while the copy caught up saves this way.
    public func updateAsRead(_ id: String, _ edit: Edit) async throws -> QueuedWrite {
        try await write { core in try core.updateItemAsRead(id: id, edit: edit) }
    }

    /// Moves an item to the bin, and queues the delete.
    public func delete(_ id: String) async throws -> QueuedWrite {
        try await write { core in try core.deleteItem(id: id) }
    }

    /// Destroys an item in the bin on the server now, and takes it, its
    /// edges and its pin out of the copy once the server accepts it.
    ///
    /// Never queued: it needs the server, and the key needs `items.purge` and
    /// write on the item's type. It is sent at `version`, the version the
    /// person was shown, such as a ``BinPage`` item's, or else the version the
    /// copy holds, so an item changed elsewhere since throws `server` with
    /// status 409 and `version_conflict`.
    ///
    /// Refused before anything is sent: an item the copy does not hold, with
    /// no `version`, throws `notFound` with the code `not_held`; one the copy
    /// shows outside the bin, such as one whose restore is queued, throws
    /// `validation` with the code `invalid_transition`; and one with a write
    /// still waiting throws `invalid`. Offline it throws `network` and a copy
    /// with no server throws `noServer`. On every failure the copy and the
    /// queue stay as they were. A `network` failure after the request went
    /// out may follow a purge the server made, which its event then shows.
    public func purge(_ id: String, version: Int64? = nil) async throws {
        try await holder.run { core in try core.purgeItem(id: id, version: version) }
        feed.announce(Change(origin: .refreshed(.purged), itemId: id, edgeId: nil))
    }

    /// One page of the server's bin, newest change first: its items in the
    /// bin, whatever the copy's slice, read online and held nowhere in the
    /// copy.
    ///
    /// Each item's `updatedAt` stands for when it went to the bin; the server
    /// answers no time of its own for that, and a write to an item in the bin
    /// moves it too. `limit` is held to 1 through 100, and a page may come
    /// back short, or empty, with a `nextCursor` still to follow. Pass the
    /// page's `nextCursor` as `after` for the next page. Offline it throws
    /// `network`, and a copy with no server throws `noServer`: the copy never
    /// answers for the bin. Restore an item with
    /// ``restore(_:)`` and destroy it with ``purge(_:version:)``.
    public func bin(type: String? = nil, after cursor: String? = nil, limit: Int = 50) async throws -> BinPage {
        try await holder.run { core in
            try core.bin(type: type, cursor: cursor, limit: UInt32(clamping: limit))
        }
    }

    /// Takes an item out of the bin, and queues the restore.
    ///
    /// An item the copy holds shows as restored at once. One it does not
    /// hold, such as an item read from ``bin(type:after:limit:)`` or one whose
    /// delete was answered, is restored by id: queued, shown nowhere until
    /// the server answers, and held once the answer or its event brings it
    /// where the slice or a pin takes it.
    public func restore(_ id: String) async throws -> QueuedWrite {
        try await write { core in try core.restoreItem(id: id) }
    }

    public func transition(_ id: String, to state: ItemState) async throws -> QueuedWrite {
        try await write { core in try core.transitionItem(id: id, state: state) }
    }

    /// Queues three writes, each with its own verdict: the upload, a file item
    /// naming the bytes, and an `attached-to` edge from the file to the item.
    public func attach(to id: String, file: URL, _ attachment: Attachment = Attachment()) async throws -> Attached {
        let attached = try await holder.run { core in
            Attached(try core.attach(id: id, path: file.path, attachment: attachment.core))
        }
        for write in [attached.upload, attached.item, attached.edge] {
            feed.announce(write)
        }
        return attached
    }

    /// Attaches `file` to the item and adds its embed to the end of the item's body, after a blank line.
    ///
    /// Queues the writes of `attach(to:file:_:)` and an edit of the body, which
    /// reads back as the attachment's own edge and makes no second one. The edit
    /// is based on the body and version the copy holds, as `update(_:_:)`'s is,
    /// so a body another device changes first is answered as the type's merge
    /// policy says: `conflicted` for a note. Where the file's title cannot name
    /// it alone in an embed, such as a title given in `attachment` that another
    /// attachment has or a name that ends in a document's extension like `.txt`,
    /// the body is left as it was.
    ///
    /// The body is read and written in two core calls, so an edit of the same
    /// body queued while this one runs is replaced, not merged: make an item's
    /// body edits one after another.
    ///
    /// Throws `EmbedFailure`, with the attachment, where the file was attached
    /// and the body step failed; any other error means nothing was written. To
    /// place the embed elsewhere, attach the file and write `Attached.embed`
    /// where it belongs.
    public func embed(file: URL, in id: String, _ attachment: Attachment = Attachment()) async throws -> Embedded {
        let (attached, body) = try await holder.run { core -> (Attached, Result<(QueuedWrite, String), any Error>) in
            let attached = Attached(try core.attach(id: id, path: file.path, attachment: attachment.core))
            return (attached, Result { try translated { try Self.writeEmbed(attached, into: id, core) } })
        }
        for write in [attached.upload, attached.item, attached.edge] {
            feed.announce(write)
        }
        let written: QueuedWrite
        let embed: String
        do {
            (written, embed) = try body.get()
        } catch {
            throw EmbedFailure(attached: attached, cause: error)
        }
        feed.announce(written)
        return Embedded(attached: attached, body: written, embed: embed)
    }

    private static func writeEmbed(_ attached: Attached, into id: String, _ core: any CoreProtocol) throws -> (
        QueuedWrite, String
    ) {
        let embed = try core.embedText(id: id, file: attached.item.itemId ?? "")
        guard let host = try core.get(id: id) else {
            throw MarfaError.notFound(code: "item_not_found", message: "\(id) is not a row this copy holds")
        }
        let field = try core.itemType(id: host.type).bodyField ?? "body"
        let body = host.properties[field]?.string ?? ""
        let separator = String(
            repeating: "\n", count: body.isEmpty ? 0 : max(0, 2 - body.reversed().prefix(while: \.isNewline).count))
        let edit = Edit(properties: [field: .string(body + separator + embed)], baseVersion: host.version)
        return (QueuedWrite(try core.updateItem(id: id, edit: edit)), embed)
    }

    /// Each link and each embed of a file in the item's body, in body order, read from the copy alone.
    ///
    /// A link or an embed names the item it resolves to, or says why it names
    /// none: `pending` until the server's lookup has answered, `missing`,
    /// `ambiguous` or `refused`. An embed resolves to the file item that holds
    /// the bytes. Throws `notFound` for an item the copy does not hold.
    public func links(in id: String) async throws -> BodyLinks {
        try await holder.run { core in BodyLinks(try core.bodyLinks(id: id)) }
    }

    /// The text that embeds `file`, an attachment of the item `id`, in that item's body: `![[title]]`.
    ///
    /// Throws `notFound` where the copy does not hold the item or the file, and
    /// `invalid` where `file` is not a file item, is not attached to the item,
    /// or has a title that cannot name it alone.
    public func embedText(of file: String, in id: String) async throws -> String {
        try await holder.run { core in try core.embedText(id: id, file: file) }
    }

    /// Adds `file` as an item of its own, attached to nothing, with a tag write for each of `tags`.
    ///
    /// Queues the upload of the bytes and a file item that names them, then one write per tag; `Added` holds the
    /// first two. `attachment` fills in what the file does not say, as for ``attach(to:file:_:)``.
    public func addFile(_ file: URL, _ attachment: Attachment = Attachment(), tags: [String] = []) async throws
        -> Added
    {
        let added = try await holder.run { core in
            Added(try core.addFile(path: file.path, attachment: attachment.core, tags: tags))
        }
        for write in [added.upload, added.item] {
            feed.announce(write)
        }
        for _ in tags {
            feed.announce(Change(origin: .local(.addTag), itemId: added.item.itemId, edgeId: nil))
        }
        return added
    }

    private func write(_ work: @escaping @Sendable (any CoreProtocol) throws -> MarfaCore.QueuedWrite) async throws
        -> QueuedWrite
    {
        try await queued(holder, feed, work)
    }
}

public struct Edges: Sendable {
    let holder: CoreHolder
    let feed: Feed

    public func from(_ id: String) async throws -> [Edge] {
        try await holder.run { core in try core.edgesFrom(id: id) }
    }

    /// The edges the copy holds to one item, unsent ones included.
    ///
    /// A hydration holds the edges going out from the slice's items, so an
    /// edge from an item outside it is held only when its type was hydrated
    /// whole or the copy pinned its source item.
    public func to(_ id: String) async throws -> [Edge] {
        try await holder.run { core in try core.edgesTo(id: id) }
    }

    /// Every edge of one type the copy holds, unsent ones included, oldest
    /// first: edges going out from held items and edge types hydrated whole.
    public func ofType(_ type: String) async throws -> [Edge] {
        try await holder.run { core in try core.edgesOfType(edgeType: type) }
    }

    /// Queues an edge.
    ///
    /// Throws `hydrationIncomplete` until the copy is whole, as ``update(_:_:)`` and ``delete(_:)`` do: a fill under
    /// way, or a stale copy's refill, leaves the edges it has not yet read unknown.
    public func create(
        from source: String, to target: String, type: String, properties: JSONObject = [:],
        id: String? = nil
    ) async throws -> QueuedWrite {
        try await write { core in
            try core.createEdge(
                draft: MarfaCore.EdgeDraft(
                    sourceId: source, targetId: target, edgeType: type,
                    properties: properties, id: id))
        }
    }

    /// Changes an edge's properties, moves one of its ends, or both, in one queued write.
    ///
    /// Refused unless `edit.baseVersion` is the version the copy holds. An edge
    /// the copy shows moved stays at its new end, read from either end, until
    /// the server answers. A move to an item whose create is still queued waits
    /// for that create. See ``EdgeEdit`` for the two refusals a move can meet.
    ///
    /// Returns `nil`, and queues and announces nothing, for an edit that names
    /// no property and no end other than the ends the copy holds: the server
    /// would raise the edge's version for a change that never happened.
    public func update(_ id: String, _ edit: EdgeEdit) async throws -> QueuedWrite? {
        let written = try await holder.run { core in
            try core.updateEdge(id: id, edit: edit.core).map(QueuedWrite.init)
        }
        if let written { feed.announce(written) }
        return written
    }

    public func delete(_ id: String) async throws -> QueuedWrite {
        try await write { core in try core.deleteEdge(id: id) }
    }

    private func write(_ work: @escaping @Sendable (any CoreProtocol) throws -> MarfaCore.QueuedWrite) async throws
        -> QueuedWrite
    {
        try await queued(holder, feed, work)
    }
}

public struct Tags: Sendable {
    let holder: CoreHolder
    let feed: Feed

    /// Queues one write that adds one tag, leaving the item's other tags.
    ///
    /// Adding several tags takes one call for each, and each is checked on
    /// its own: a call that would add a tag to an item that would then hold more
    /// than 100 throws `validation_error`, and the tags added before it stay
    /// added and queued.
    /// To set every tag in one write, use ``Metadata/replaceTags(of:with:)``.
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
}

public struct Extensions: Sendable {
    let holder: CoreHolder
    let feed: Feed

    public func write(_ namespace: String, _ body: JSONObject, on id: String) async throws -> QueuedWrite {
        try await queued(holder, feed) { core in
            try core.writeExtension(id: id, namespace: namespace, body: body)
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

    /// Calls `body` with where a blob's bytes are held, fetching them first
    /// when they are not.
    ///
    /// The file stays in the cache until `body` returns or throws, however
    /// many other blobs are fetched meanwhile and whatever the cache budget.
    /// Once it returns, a later trim can take the file, so read it inside
    /// `body` and copy it out if it must outlast the call.
    ///
    /// A reader, or a copy without a server, throws `bytesAbsent` instead of
    /// fetching.
    public func withFile<Result>(
        _ hash: String, isolation: isolated (any Actor)? = #isolation,
        _ body: (URL) async throws -> Result
    ) async throws -> Result {
        let lease = try await holder.run { core in try core.blob(hash: hash) }
        defer { withExtendedLifetime(lease) {} }
        return try await body(URL(fileURLWithPath: lease.path()))
    }

    public func isHeld(_ hash: String) async throws -> Bool {
        try await holder.run { core in try core.blobHeld(hash: hash) }
    }

    /// The cache of fetched files: its setting, the budget in force, the bytes held, and the attachments kept
    /// outside the budget.
    ///
    /// Read from the copy with no request, as `status().fileCache` is. `attachments` is `nil` from the start of a
    /// hydration until one completes, and where the cache could not be read.
    public func cache() async throws -> FileCache {
        try await holder.run { core in try core.fileCache() }
    }

    /// Chooses how the cache's budget is set, trims the cache to it at once, and returns the bytes the trim took.
    ///
    /// The choice is kept in the store, so a copy opened again uses it. Files attached to items the copy holds
    /// stay outside the budget, and a file being read inside ``withFile(_:isolation:_:)`` is never trimmed. Throws
    /// `readingHandle` for a reader.
    public func setBudget(_ budget: FileBudget) async throws -> UInt64 {
        try await holder.run { core in try core.setFileBudget(budget: budget) }
    }

    /// Trims the cache to its budget now.
    ///
    /// Returns the bytes it took. Throws `readingHandle` for a reader.
    public func trim() async throws -> UInt64 {
        try await holder.run { core in try core.trimFiles() }
    }

    /// Fetches the bytes of every file attached to an item the copy holds that the cache does not hold whole,
    /// smallest first, so they are there offline.
    ///
    /// Run it after a hydration and after a catch-up. It resumes the part of a file an earlier fetch left. It waits
    /// out a server that asks for a wait of a minute or less. It stops at the first file the disk has no room for,
    /// once the server cannot be reached, or once the server asks for a longer wait; a file that fails otherwise is
    /// passed over. The report, and `status().fileCache.attachments`, say what is still not held and why.
    ///
    /// Canceling the task stops it and throws `canceled`; the files it had fetched stay. Throws `readingHandle`
    /// for a reader and for a folder's copy, and `noServer` for a copy without a server.
    public func fetchKept() async throws -> KeptFetch {
        try await holder.runUntilCanceled { core, stop in try core.fetchKept(stop: stop) }
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
    /// A held `changes()` stream also drains once when its server is back,
    /// and once after a drain left a write undelivered; otherwise nothing
    /// drains on its own.
    public func drain() async throws -> DrainReport {
        let report = DrainReport(try await holder.runUntilCanceled { core, stop in try core.drain(stop: stop) })
        for change in report.changes() { feed.announce(change) }
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
    /// Only a write blocked `ancestorUnavailable`, `conflictUnresolved` or
    /// `failingAlone` is taken; `false` for any other. Writes waiting on it
    /// are refused unsent. It reads the row from the server first, so it needs
    /// the server, and returns `false` when the copy moved during the read;
    /// ask again.
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
    ///
    /// Tells every held stream `.refreshed(.forgotten)` when it cleared a
    /// write, and nothing when it cleared none.
    public func forgetAnswered() async throws -> UInt64 {
        let forgotten = try await holder.run { core in try core.forgetAnswered() }
        announceForgotten(forgotten > 0)
        return forgotten
    }

    /// Clears only the named answered writes, under the rules
    /// `forgetAnswered()` keeps, and returns how many went.
    ///
    /// Every other answered write stays, so an app clears just the answers it
    /// has read; a drain that ran since, such as the one a held `changes()`
    /// stream makes when its server is back, leaves its answers for the next
    /// read. An id that names no write, or a write with no answer yet, is
    /// ignored, and an empty list clears nothing. It tells every held stream
    /// `.refreshed(.forgotten)` when it cleared a write, and nothing when it
    /// cleared none.
    public func forgetAnswered(ids: [String]) async throws -> UInt64 {
        let forgotten = try await holder.run { core in try core.forgetAnsweredIds(ids: ids) }
        announceForgotten(forgotten > 0)
        return forgotten
    }

    /// Takes a refused write, and the content it carried, out of the queue.
    ///
    /// `false` for a write that is not refused, or that a waiting write
    /// still depends on, and `notFound` for an id the queue does not hold.
    /// A create refused onto a row its natural key names that no read has
    /// found is taken even with writes waiting on it, and they are refused
    /// unsent. A create's discard first waits for a drain already running to
    /// end.
    /// The copy's row already shows what the server holds.
    ///
    /// Tells every held stream `.refreshed(.forgotten)` when it took the
    /// write, and nothing when it returns `false`.
    public func discard(_ id: String) async throws -> Bool {
        let discarded = try await holder.run { core in try core.discard(id: id) }
        announceForgotten(discarded)
        return discarded
    }

    private func announceForgotten(_ cleared: Bool) {
        guard cleared else { return }
        feed.announce(Change(origin: .refreshed(.forgotten), itemId: nil, edgeId: nil))
    }
}

/// Queues one write and tells every held stream of it.
func queued(
    _ holder: CoreHolder, _ feed: Feed, _ work: @escaping @Sendable (any CoreProtocol) throws -> MarfaCore.QueuedWrite
)
    async throws -> QueuedWrite
{
    let written = try await holder.run { QueuedWrite(try work($0)) }
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
    }
}
