import Foundation
import Synchronization

// MARK: - SSE event payload envelopes

private struct ItemEventPayload: Decodable {
    let item: Item
}

private struct EdgeEventPayload: Decodable {
    let edge: Edge
}

private struct MetadataEventPayload: Decodable {
    let itemId: String
    let metadata: Metadata

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case metadata
    }
}

// MARK: - SyncEngine

/// Drives bidirectional synchronization between the local SQLite store and the
/// Marfa server.
///
/// ## Lifecycle
///
///     let engine = SyncEngine(
///         transport: transport,
///         localStore: store,
///         mutationQueue: queue,
///         connectionManager: connManager
///     )
///     await engine.start()  // begin; returns immediately
///     // ...
///     await engine.stop()   // tear down gracefully
///
/// ## What the engine does
///
/// 1. **Watches ``ConnectionStateManager``** — when the path goes from offline
///    to connecting, the engine catches up and then opens a `GET /events` SSE
///    stream with the last persisted `Last-Event-ID` cursor so it receives only
///    events since the previous session.
///
/// 2. **Catches up before it subscribes** — the stream carries only what
///    happens after it opens, so coming online drains the mutation queue if
///    anything is in it and then imports the library if this store has never
///    completed an import. Without that step a freshly signed-in app shows an
///    empty store, and a write queued while the engine was stopped is never
///    replayed. One catch-up runs at a time; an explicit
///    ``performInitialSync(pageSize:)`` issued while one is in flight joins it.
///
/// 3. **Applies SSE events** — each server-sent event is decoded and written
///    into the local store via ``LocalStore`` upsert helpers. Supported event
///    types: `item.created`, `item.updated`, `item.deleted`, `item.restored`,
///    `item.state_changed`, `edge.created`, `edge.deleted`,
///    `metadata.changed`.
///
/// 4. **Persists the Last-Event-ID cursor** — after, and only after, the
///    event has been written to the local store. Reconnection resumes strictly
///    after the cursor, so an event the cursor has passed is never sent again;
///    recording progress first would mean a failed write loses the event for
///    good. A write the store refuses ends the stream, because a later event
///    would otherwise carry the cursor past the one that never landed.
///
/// 5. **Replays the mutation queue** — on coming online, within a short
///    debounce of any new enqueue, and again when the stream closes, the
///    engine drains ``MutationQueue`` by sending each pending mutation to the
///    server. On success the record is removed; on failure the attempt count
///    is incremented and the engine retries on the next cycle.
///
/// 6. **Coordinates state** — the engine calls ``ConnectionStateManager``
///    `.markSyncing()` while replaying mutations and `.markOnline()` once the
///    stream is open, so everything gated on being online stays reachable for
///    as long as it stays open rather than only after it closes.
public actor SyncEngine {

    // MARK: - Dependencies

    private let transport: any Transport
    private let localStore: any LocalStoreWriting
    private let mutationQueue: MutationQueue
    /// The app's live conflict resolver, looked up when replaying a mutation
    /// queued with `.callback`. Held by the client so registration survives
    /// the closure that could not be.
    private let conflictResolvers: ConflictResolverRegistry?
    private let connectionManager: ConnectionStateManager
    private let logger = MarfaLogger(category: "sync")

    /// Debounce window between a `MutationQueue.drainRequests` ping and
    /// the proactive drain firing. Coalesces bursts of enqueues from a
    /// single user action (e.g. `setMetadata` + `addTags` back-to-back)
    /// into one replay cycle. Default 150 ms — long enough to gather a
    /// typed burst, short enough to feel instant.
    private let drainDebounceInterval: Duration

    // MARK: - Internals

    private var streamTask: Task<Void, Never>?
    private var stoppingTask: Task<Void, Never>?
    private var running = false
    private var starting = false
    private var lifecycleGeneration: UUID?

    // Deterministic seam for the actor-reentry window after the
    // ConnectionStateManager start hop and before task publication.
    private var shouldSuspendNextStartPublicationForTesting = false
    private var startPublicationContinuationForTesting: CheckedContinuation<Void, Never>?

    // Deterministic seams for the two actor-reentry windows in `openStream`
    // that run after the stream has closed. Both windows are microseconds wide
    // in production, so a lifecycle regression in either is invisible to a
    // timing-based test; the seams widen them on demand.
    internal enum StreamSuspendPointForTesting: Sendable, Equatable {
        /// Between the stream closing and the `.online` transition.
        case beforeMarkOnline
        /// Between the `.online` transition and the reconnect nudge.
        case beforeReconnectSchedule
    }

    private var streamSuspendPointForTesting: StreamSuspendPointForTesting?
    private var streamSuspendContinuationForTesting: CheckedContinuation<Void, Never>?

    /// Child task listening to `mutationQueue.drainRequests`. Feeds
    /// `drainDebounceTask` — one schedule-and-coalesce cycle per burst.
    /// Cancelled on `stop()`.
    private var drainListenerTask: Task<Void, Never>?

    /// Debounce task for the proactive drain. Cancelled-and-replaced on
    /// each new `drainRequests` ping so a steady stream of enqueues
    /// fires one replay at the end, not per-ping.
    private var drainDebounceTask: Task<Void, Never>?

    /// Guard against overlapping replays. The SSE-close path and the
    /// proactive-drain path both call ``replayMutations``; without this
    /// flag, a ping arriving mid-replay would kick off a second cycle
    /// against the same records. Set on entry, released in `defer`.
    private var draining = false

    /// Detached task that sleeps for the reconnect back-off and then flips
    /// ``ConnectionStateManager`` back to `.connecting`. Detached so the
    /// SSE consumer loop inside `openStream` can return promptly and let
    /// ``runLoop`` observe any state changes (network drop, test-driven
    /// transition, `catchup_too_old` finalize) that happen during the wait.
    /// Cancelled and replaced on every reconnect cycle and on `stop()`.
    private var reconnectTask: Task<Void, Never>?

    /// The import currently in flight, if any. One catch-up at a time: a
    /// reconnect, a retention-gap resync and a consumer's own
    /// ``performInitialSync(pageSize:)`` all join whichever run is already
    /// going rather than paging the library again beside it. Both shipping
    /// apps call the import themselves today, and those calls do not
    /// disappear the day the engine starts making it too.
    private var importTask: Task<Int, Error>?

    // Sync-state keys stored in the mutation-queue's sync_state table.
    private let cursorKey = "last_event_id"
    private let fullSyncKey = "last_full_sync_at"
    private let cleanDrainKey = "last_clean_drain_at"

    /// In-memory record of the most recent transient drain failure.
    /// Cleared by the next clean drain. Not persisted — a cold start
    /// mid-failure rolls back to whatever the persisted clean-drain
    /// timestamp says (or ``FullSyncState/notYetSynced``).
    private var lastFailedError: Error?
    private var lastFailedAt: Date?

    // MARK: - Event stream

    /// Reactive stream of typed sync events for app subscribers (e.g. a
    /// SwiftUI view backing a "Last synced" footer or a merge-toast surface).
    /// Past events are not replayed to late subscribers; the engine yields
    /// each event once per running consumer.
    ///
    /// Subscription completes before the property returns, so a caller that
    /// takes a stream and immediately calls ``stop()`` gets a finished stream
    /// rather than one that never yields and never ends. Every open stream
    /// finishes when ``stop()`` reaches quiescence; a restarted engine hands
    /// out fresh streams.
    public nonisolated var events: AsyncStream<SyncEvent> {
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream()
        subscribers.withLock { $0.append(continuation) }
        return stream
    }

    /// Held under a mutex rather than in actor state so that subscription is
    /// synchronous with the `events` access. Registering through a detached
    /// task instead would let a `stop()` issued right after subscribing run
    /// first, leaving the new continuation attached to a stopped engine and
    /// its consumer awaiting an event that can never arrive.
    private let subscribers = Mutex<[AsyncStream<SyncEvent>.Continuation]>([])

    private func emit(_ event: SyncEvent) {
        subscribers.withLock { continuations in
            continuations.removeAll { continuation in
                if case .terminated = continuation.yield(event) { return true }
                return false
            }
        }
    }

    /// Ends every open ``events`` stream. Called once ``stop()`` has reached
    /// quiescence, so subscribers see the final events of the cycle first.
    private nonisolated func finishEventSubscribers() {
        let open = subscribers.withLock { continuations in
            defer { continuations.removeAll() }
            return continuations
        }
        for continuation in open {
            continuation.finish()
        }
    }

    /// Actor-hopped shim used by the blob-upload progress delegate.
    /// `URLSession`'s delegate callbacks fire off-actor, and forwarding
    /// the closure through a detached `Task { await self?.emitBlobProgress }`
    /// keeps all event emission on the engine's executor.
    private func emitBlobProgress(
        hash: String,
        bytesUploaded: Int64,
        totalBytes: Int64
    ) {
        emit(.blobUploadProgress(
            hash: hash,
            bytesUploaded: bytesUploaded,
            totalBytes: totalBytes
        ))
    }

    // MARK: - Sync status (consumer-facing signals)

    /// `true` when the mutation queue holds one or more pending writes that
    /// haven't yet been replayed to the server. Consumers can read this
    /// before deciding whether to trigger a user-visible "unsynced changes"
    /// affordance, or to defer a fresh pull until the local queue has drained.
    ///
    /// Thin actor-isolated wrapper over ``MutationQueue/isEmpty`` — rethrows
    /// any storage-layer read error so callers can distinguish "no pending
    /// mutations" from "couldn't check".
    public var hasPendingMutations: Bool {
        get async throws {
            !(try await mutationQueue.isEmpty)
        }
    }

    /// Timestamp of the most recent successful ``performInitialSync(pageSize:)``
    /// completion against this local store, or `nil` if one has never run.
    /// Persisted in the `sync_state` table so the value survives app restarts
    /// and is keyed to the on-disk store (not the client instance).
    ///
    /// Consumers can read this before deciding whether to trigger a fresh
    /// initial sync — a `nil` value or one that's older than the consumer's
    /// freshness budget is a signal to pull, even when the local store already
    /// holds items from an earlier session.
    ///
    /// Serialized as ISO 8601 with fractional seconds
    /// (`Date.ISO8601FormatStyle(includingFractionalSeconds: true)`). Returns
    /// `nil` when the value is absent or fails to parse — unreadable and
    /// never-synced are indistinguishable to the caller and both warrant a
    /// pull.
    public var lastFullSyncAt: Date? {
        get async {
            guard
                let raw = try? await mutationQueue.loadSyncState(key: fullSyncKey),
                let parsed = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            else {
                return nil
            }
            return parsed
        }
    }

    /// Timestamp of the most recent clean drain cycle — both the SSE
    /// event application and the queued-mutation replay completed
    /// without an outstanding error. Stamped from inside
    /// ``replayMutations()`` whenever the cycle finishes cleanly (queue
    /// drained or already empty); persisted in `sync_state` under
    /// `last_clean_drain_at`.
    ///
    /// Distinct from ``lastFullSyncAt``, which only stamps on
    /// ``performInitialSync(pageSize:)`` completion. Apps that want
    /// "have we ever pulled from the server?" read ``lastFullSyncAt``;
    /// apps that want "is the local store currently caught up?" read
    /// this accessor or subscribe via ``MarfaStore/queryFullSyncState()``.
    ///
    /// Serialized as ISO 8601 with fractional seconds; returns `nil`
    /// when absent or unparseable.
    public var lastCleanDrainAt: Date? {
        get async {
            guard
                let raw = try? await mutationQueue.loadSyncState(key: cleanDrainKey),
                let parsed = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            else {
                return nil
            }
            return parsed
        }
    }

    /// Point-in-time read of the engine's ``FullSyncState``.
    ///
    /// Order of precedence:
    /// 1. ``FullSyncState/syncing`` if a drain cycle is currently in flight.
    /// 2. ``FullSyncState/failed(at:error:)`` if the most recent cycle
    ///    bailed and no later clean drain has cleared it.
    /// 3. ``FullSyncState/synced(at:)`` if a clean drain timestamp is
    ///    persisted.
    /// 4. ``FullSyncState/notYetSynced`` otherwise.
    ///
    /// ``MarfaStore/queryFullSyncState()`` returns a reactive
    /// `@Observable` view backed by the same signals; prefer that for
    /// SwiftUI views.
    public var fullSyncState: FullSyncState {
        get async {
            if draining { return .syncing }
            if let err = lastFailedError, let at = lastFailedAt {
                return .failed(at: at, error: err)
            }
            if let stamped = await lastCleanDrainAt {
                return .synced(at: stamped)
            }
            return .notYetSynced
        }
    }

    // MARK: - Init

    public init(
        transport: any Transport,
        localStore: any LocalStoreWriting,
        mutationQueue: MutationQueue,
        connectionManager: ConnectionStateManager,
        drainDebounceInterval: Duration = .milliseconds(150),
        conflictResolvers: ConflictResolverRegistry? = nil
    ) {
        self.transport = transport
        self.localStore = localStore
        self.mutationQueue = mutationQueue
        self.connectionManager = connectionManager
        self.drainDebounceInterval = drainDebounceInterval
        self.conflictResolvers = conflictResolvers
    }

    // MARK: - Lifecycle

    /// Starts the sync engine. Idempotent — calling again while already running
    /// is a no-op. Also starts the underlying ``ConnectionStateManager`` (which
    /// is itself idempotent) so `NWPathMonitor` begins delivering reachability
    /// updates; without this the engine's run loop would await on an inert
    /// stream stuck at `.offline`.
    ///
    /// This is the whole of the setup a synced client needs. Coming online
    /// catches the store up — queued writes replay and a store that has never
    /// synced imports the library — before the event stream opens, so there is
    /// no second call to remember and none to forget. Watch
    /// ``fullSyncState`` or ``MarfaStore/queryFullSyncState()`` to render
    /// progress while a first import runs.
    public func start() async {
        while let stoppingTask {
            await stoppingTask.value
            // The stop owner clears `stoppingTask` after observing the same
            // barrier. Yield so a resumed start cannot publish a new
            // generation while that owner still considers stop in progress.
            await Task.yield()
        }
        guard !running, !starting else { return }
        let generation = UUID()
        lifecycleGeneration = generation
        starting = true
        await connectionManager.start()
        // A manager the app started itself may already be sitting on
        // `.online`, and `ConnectionStateManager.start()` is idempotent, so
        // the call above installs no second monitor and no fresh path update
        // arrives to move it. `runLoop` opens a stream on `.connecting` and
        // only there, deliberately — that is its one entry, and the state the
        // engine publishes on an open stream is `.online`, so treating that as
        // an entry too would reopen the stream it just opened. Nudge instead,
        // exactly as the reconnect path does.
        if connectionManager.state == .online {
            await connectionManager.markConnecting()
        }
        // Subscribe to the drain pings before `start()` returns rather than
        // from inside the listener task. `MutationQueue.drainRequests`
        // registers its continuation synchronously with the access precisely
        // so a subscription cannot race the first enqueue, and taking the
        // stream inside the task hands that race straight back one level up:
        // the task's own first suspension is that access, so a write made
        // while it is still pending emits a ping with nobody registered, and
        // late subscribers never see a past one.
        let drainRequests = await mutationQueue.drainRequests
        await suspendStartPublicationIfNeededForTesting()
        guard starting, lifecycleGeneration == generation else { return }
        starting = false
        running = true
        streamTask = Task { [weak self] in
            await self?.runLoop()
        }
        drainListenerTask = Task { [weak self] in
            await self?.drainListenerLoop(drainRequests)
        }
    }

    /// Stops the sync engine and waits for it to go quiet.
    ///
    /// Cancellation alone is a request, not an outcome: an in-flight mutation
    /// replay or SSE handler observes it at its next suspension point and may
    /// still be mid-accounting when the cancel returns. `stop()` therefore
    /// cancels, then awaits every task the engine owns, so that when it
    /// returns no engine-owned work is still running and nothing can write
    /// into the stopped lifecycle. Callers that only want to signal shutdown
    /// without waiting should call it from a task of their own.
    ///
    /// Also stops the underlying ``ConnectionStateManager`` so `NWPathMonitor`
    /// releases its queue and any open `stateUpdates` streams finish, and
    /// finishes every open ``events`` stream.
    ///
    /// Concurrent calls share one barrier — a second `stop()` awaits the same
    /// quiescence point rather than starting a second teardown. A ``start()``
    /// issued during a stop waits for that barrier before opening a new
    /// lifecycle.
    ///
    /// An import in flight is one of those tasks. It is unstructured and can
    /// run for as long as a library takes to page, so it is cancelled with the
    /// rest rather than awaited to completion — otherwise `stop()` blocks for a
    /// whole import and the paragraph above is not true. A cancelled import
    /// stamps nothing, so the next cycle runs it again.
    ///
    /// The wait is bounded by the transport honoring cancellation on its
    /// in-flight request. ``URLSessionTransport`` does; a custom ``Transport``
    /// that ignores cancellation can hold `stop()` open for as long as its
    /// request runs.
    public func stop() async {
        if let stoppingTask {
            await stoppingTask.value
            return
        }

        lifecycleGeneration = nil
        starting = false
        running = false
        let streamTask = self.streamTask
        let drainListenerTask = self.drainListenerTask
        let drainDebounceTask = self.drainDebounceTask
        let reconnectTask = self.reconnectTask
        let importTask = self.importTask
        importTask?.cancel()
        self.importTask = nil
        streamTask?.cancel()
        self.streamTask = nil
        drainListenerTask?.cancel()
        self.drainListenerTask = nil
        drainDebounceTask?.cancel()
        self.drainDebounceTask = nil
        reconnectTask?.cancel()
        self.reconnectTask = nil

        let connectionManager = self.connectionManager
        let barrier = Task { @concurrent in
            // Finish the source streams first so listener tasks can unwind,
            // then await every task that was owned by this engine generation.
            // Cancellation is cooperative: awaiting the values is what makes
            // stop() a quiescence boundary rather than a cancellation request.
            await connectionManager.stop()
            await streamTask?.value
            await drainListenerTask?.value
            await drainDebounceTask?.value
            await reconnectTask?.value
            _ = try? await importTask?.value
            await self.drainResidualLifecycleTasks()
            self.finishEventSubscribers()
        }
        stoppingTask = barrier
        await barrier.value
        stoppingTask = nil
    }

    /// Awaits any task installed into a lifecycle slot after `stop()` took its
    /// snapshot. A path already past its own `running` check when the snapshot
    /// was taken can still publish one task; the snapshot cannot see it, so
    /// awaiting only the snapshot would let `stop()` return with live work.
    /// Terminates because `running` is already false and `stoppingTask` is
    /// still set, so no path can install another round.
    ///
    /// This is the single mechanism enforcing that contract, deliberately.
    /// Each install site could instead re-check `running` immediately before
    /// publishing, and one that does makes this sweep find nothing — but then
    /// neither the sweep nor the re-check is falsifiable, because either one
    /// alone produces a quiet teardown and removing either leaves the suite
    /// green. Concentrating the guarantee here keeps it provable, and covers
    /// every slot rather than the one path that happened to be noticed.
    private func drainResidualLifecycleTasks() async {
        while hasLifecycleTasks {
            let residual = [streamTask, drainListenerTask, drainDebounceTask, reconnectTask]
            let residualImport = importTask
            streamTask = nil
            drainListenerTask = nil
            drainDebounceTask = nil
            reconnectTask = nil
            importTask = nil
            for task in residual { task?.cancel() }
            residualImport?.cancel()
            for task in residual { await task?.value }
            _ = try? await residualImport?.value
        }
    }

    private var hasLifecycleTasks: Bool {
        streamTask != nil || drainListenerTask != nil
            || drainDebounceTask != nil || reconnectTask != nil
            || importTask != nil
    }

    /// Performs a one-shot catch-up import: paginates through `GET
    /// /items?include=metadata` and then `GET /edges`, upserting each item,
    /// its metadata, and every edge into the local store. SSE alone only
    /// delivers events since the cursor, so without this call a freshly
    /// signed-in app shows an empty store even when the server has history.
    ///
    /// Safe to call repeatedly — `upsertItem`, `setMetadata` and `upsertEdge`
    /// are all idempotent.
    ///
    /// - Parameter pageSize: Server-side page size for each request. Clamped
    ///   to 500 for the edge pass, which is that route's ceiling.
    /// - Returns: The number of *items* imported across all pages. Edges are
    ///   imported too and their count is logged rather than returned, because
    ///   widening the return type would break every existing call site to
    ///   report a number no caller currently asks for.
    /// - Throws: Transport errors from the pagination requests, or upsert
    ///   errors from the local store.
    /// Counts callers currently inside ``performInitialSync(pageSize:)``,
    /// owner and joiners alike. A test proving that two callers share one
    /// import has to know both have arrived before it releases the first, and
    /// every other way of knowing that is a sleep racing the thing it measures.
    internal private(set) var importCallerCountForTesting = 0

    @discardableResult
    public func performInitialSync(pageSize: Int = 200) async throws -> Int {
        importCallerCountForTesting += 1
        defer { importCallerCountForTesting -= 1 }

        // Join a run already going, or publish this one — with nothing
        // suspending between the two, so a caller entering on actor reentry
        // finds the task rather than starting a second one beside it. The
        // refusal moves inside the task for exactly that reason: asking the
        // queue first would open a gap between the check and the publication,
        // and a caller arriving mid-catch-up is asking for the import that is
        // already happening rather than for a fresh decision about it.
        if let importTask {
            // The refusal runs inside the owner's task, so a joiner would slip
            // past it. Ask again here: a caller that has queued work since the
            // import began is still asking to overwrite it, and arriving late
            // is not consent.
            try await refuseIfWorkIsStillQueued()
            return try await importTask.value
        }
        let task = Task { [self] in
            try await refuseIfWorkIsStillQueued()
            return try await importPasses(pageSize: pageSize)
        }
        importTask = task
        defer { if importTask == task { importTask = nil } }
        return try await task.value
    }

    /// Refuses the import while the queue still holds work, rather than
    /// overwriting it. Every row the import receives goes through
    /// `upsertItem`, which replaces all of an item's columns with no version
    /// check, and `setMetadata`, whose contract is replace rather than merge.
    /// The conflict machinery is unreachable from here — it only runs on an
    /// outbound update meeting a 409. So an edit made offline and still queued
    /// loses to the server's older body, with nothing reporting it.
    ///
    /// The check belongs here rather than in the caller. A consumer cannot ask
    /// this question at the moment it needs to: `hasPendingMutations` hangs off
    /// this engine, and the caller deciding whether to import is typically
    /// holding a local client that has neither an engine nor a queue. What it
    /// writes instead is `syncEngine?.hasPendingMutations ?? false`, which
    /// answers "safe" because there was nothing to ask — a presence check
    /// standing in for a liveness check, and one that reads as correct. Here
    /// the queue is in hand, so the answer cannot be right by accident.
    ///
    /// Per-row skipping was the other option and it cannot be made complete: a
    /// mutation carries an optional `localId`, and the three bulk enqueues set
    /// none at all, so a bulk write is invisible to any "does item X have a
    /// pending edit" test.
    ///
    /// The engine's own catch-up drains before it asks, which is what clears
    /// the way rather than working around this.
    private func refuseIfWorkIsStillQueued() async throws {
        let pending = try await mutationQueue.pendingCount
        if pending > 0 {
            throw InitialSyncError.pendingMutations(count: pending)
        }
    }

    /// The import itself, with no refusal and no coalescing — both belong to
    /// the callers above, which is what lets the catch-up drain first and then
    /// reach the same passes an explicit caller reaches.
    private func importPasses(pageSize: Int) async throws -> Int {
        var cursor: String? = nil
        var imported = 0
        repeat {
            // `stop()` cancels this task, and a page loop that never asks
            // would keep paging a whole library past the teardown that was
            // meant to end it.
            try Task.checkCancellation()
            var query: [(String, String)] = [
                ("limit", String(pageSize)),
                ("include", "metadata"),
            ]
            if let cursor { query.append(("cursor", cursor)) }

            let page: PaginatedResult<ItemWithMetadata> = try await transport.request(
                method: .get, path: "/items", body: nil, query: query
            )

            for pair in page.data {
                try await localStore.upsertItem(pair.item)
                let input = MetadataInput(tags: pair.metadata.tags)
                _ = try await localStore.setMetadata(itemId: pair.item.id, input: input)
                imported += 1
            }

            if !page.hasMore {
                break
            }
            cursor = page.cursor
        } while cursor != nil

        // Edges, on the same one-shot basis, and not a nicety. Edge reads
        // resolve against the local store whenever one exists, so a store with
        // no edge rows shows a library with no relationships — Related empty,
        // a thread showing a root with no replies, attachments showing none.
        // SSE carries only events after the cursor, so edges created before
        // this device signed in are never emitted to it and the gap is
        // permanent rather than eventual. This pass is the only thing that
        // closes it.
        //
        // Order against the items above does not matter: an edge holds its
        // endpoints as plain id columns with no relationship, precisely so an
        // edge whose item has not arrived is stored rather than refused.
        //
        // Through `transport` rather than `edges.list`, which in synced mode
        // answers from the very table this is filling.
        var edgeCursor: String? = nil
        var edgesImported = 0
        repeat {
            try Task.checkCancellation()
            // 500 is the route's own ceiling; a larger `limit` is refused
            // rather than clamped.
            var query: [(String, String)] = [("limit", String(min(pageSize, 500)))]
            if let edgeCursor { query.append(("cursor", edgeCursor)) }

            let page: PaginatedResult<Edge> = try await transport.request(
                method: .get, path: "/edges", body: nil, query: query
            )

            for edge in page.data {
                try await localStore.upsertEdge(edge)
                edgesImported += 1
            }

            if !page.hasMore {
                break
            }
            edgeCursor = page.cursor
        } while edgeCursor != nil

        logger.log.info(
            "sync.initial_sync items=\(imported, privacy: .public) edges=\(edgesImported, privacy: .public)"
        )

        // Stamp the completion so consumers can gate fresh pulls on recency
        // rather than "is the local store empty?". Uses the same ISO 8601
        // with fractional seconds as the mutation queue's created_at for
        // consistency and to stay off the non-Sendable `ISO8601DateFormatter`.
        let stamp = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        try? await mutationQueue.saveSyncState(key: fullSyncKey, value: stamp)

        return imported
    }

    // MARK: - Main run loop

    private func runLoop() async {
        for await state in connectionManager.stateUpdates {
            guard running else { break }

            switch state {
            case .connecting:
                await openStream()
            case .offline:
                // Stream will be cancelled by Task cancellation if needed; do nothing.
                break
            case .online, .syncing:
                break
            }
        }
    }

    // MARK: - Catch-up

    /// Brings the local store level with the server. Runs whenever the engine
    /// comes online, before the event stream opens, and again from the
    /// retention-gap branch below.
    ///
    /// Two things can be behind and they settle in this order. Writes made
    /// while the engine was down replay first, because the import replaces
    /// every row it receives with no version check and would otherwise
    /// overwrite them — which is also why the import refuses outright over a
    /// queue that has not drained, and why draining is the only thing that can
    /// clear the way for it. Then the library itself is pulled, but only for a
    /// store that has never completed an import: nothing else ever fills a
    /// fresh one, and a store that has been filled must not re-page the whole
    /// library on every reconnect.
    ///
    /// **The import decision reads `last_full_sync_at`, not
    /// ``fullSyncState``**, and the difference is load-bearing in both
    /// directions. The drain above stamps a clean drain, so `fullSyncState`
    /// would already read `.synced` by the time the import was considered and
    /// a fresh store with a queued write would never be filled. And a clean
    /// drain following a *failed* import clears the failure, so a device whose
    /// import failed would read `.synced` on the next cycle and never try
    /// again. `last_full_sync_at` is stamped by a completed import and by
    /// nothing else, which is the question actually being asked.
    ///
    /// - Parameter forceImport: import even for a store that has completed one
    ///   before. The retention-gap branch sets it: the server has discarded
    ///   the events this device's cursor points at, so the store is behind by
    ///   an unknown amount and only a fresh import closes that.
    @discardableResult
    private func catchUp(forceImport: Bool = false) async -> Error? {
        // A queue that cannot be read is drained rather than skipped:
        // `replayMutations` reports the storage failure, where assuming empty
        // would walk into an import that overwrites whatever is in there.
        let queueIsEmpty = (try? await mutationQueue.isEmpty) ?? false
        if !queueIsEmpty {
            await replayMutations()
            // A drain leaves the manager on `.syncing`. Everything gated on
            // `.online` has to be reachable again once it is over, and when
            // this runs mid-stream from the retention-gap branch nothing
            // else will put it back.
            if running { await connectionManager.markOnline() }

            // A drain that did not empty the queue leaves work the import
            // refuses over, and that refusal would replace the drain's error
            // in ``fullSyncState`` with one about the import — reporting the
            // consequence and hiding the cause. Leave the cause standing and
            // let the next cycle try again.
            let drained = (try? await mutationQueue.isEmpty) ?? false
            guard drained else {
                logger.log.info("sync.catch_up.import_skipped reason=queue_not_drained")
                return nil
            }
        }

        let hasImported = await lastFullSyncAt != nil
        guard forceImport || !hasImported else { return nil }

        do {
            _ = try await performInitialSync()
            // The queue is empty and the library is level, which is what a
            // clean drain already means; this is the existing check, asked at
            // one more point rather than a second definition. Without it the
            // state would sit at `.notYetSynced` until something closed the
            // stream, and against a live server nothing does.
            await recordCleanDrainIfQueueIsEmpty()
            return nil
        } catch {
            // Recorded and left visible rather than escalated. The caller
            // opens the stream after this returns either way: a device whose
            // import failed should not also be deaf to what happens next, and
            // the next online cycle asks again because the import stamped
            // nothing. Returned as well as recorded so a caller with more
            // context than this can say where it happened.
            recordSyncFailure(error)
            return error
        }
    }

    // MARK: - Proactive drain on enqueue

    /// Listens to `mutationQueue.drainRequests` for the lifetime of the
    /// engine. Each ping schedules a debounced proactive drain — bursts
    /// of enqueues collapse into one replay cycle at the end.
    private func drainListenerLoop(_ stream: AsyncStream<Void>) async {
        for await _ in stream {
            guard running else { break }
            scheduleProactiveDrain()
        }
    }

    /// Cancels any pending debounce task and replaces it with a fresh
    /// one. Sleeps for ``drainDebounceInterval`` before firing. The
    /// actor hop from the detached task back into the engine happens
    /// inside ``fireProactiveDrain`` — scheduling is cheap and synchronous.
    private func scheduleProactiveDrain() {
        drainDebounceTask?.cancel()
        let interval = drainDebounceInterval
        drainDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            await self?.fireProactiveDrain()
        }
    }

    /// Fires a proactive drain iff we're running, not already draining,
    /// and `ConnectionStateManager` reports `.online`. All other states
    /// are no-ops:
    ///
    /// - `.offline` — no server to drain to; next `NWPathMonitor`
    ///   transition picks up the queue.
    /// - `.connecting` — SSE stream is opening and will drain the queue
    ///   on close via the existing ``openStream`` path.
    /// - `.syncing` — another drain is already in flight; the current
    ///   one will pick up this record on its next iteration.
    ///
    /// On fire, follows the same shape as the SSE-close path: replay,
    /// then mark online if still running.
    private func fireProactiveDrain() async {
        guard running, !draining else { return }
        let state = connectionManager.state
        guard state == .online else { return }
        await replayMutations()
        if running { await connectionManager.markOnline() }
    }

    /// Test hook — drives the proactive drain's state gate deterministically
    /// without going through the debouncer or the drain-request stream.
    /// `NWPathMonitor` races with the test seam on networked dev machines,
    /// so unit tests that want to exercise the `.offline` / `.syncing`
    /// branches call here instead of relying on engine-started state. Mirrors
    /// what ``drainListenerLoop`` does after the debounce sleep. `internal`
    /// so `@testable import MarfaSDK` can reach it; not public API.
    internal func triggerProactiveDrainForTesting() async {
        // Flip `running` true so the gate inside `fireProactiveDrain` does
        // not short out on a not-started engine. The rest of the guard
        // chain (`draining` overlap, connection-state check) still applies.
        let wasRunning = running
        running = true
        await fireProactiveDrain()
        running = wasRunning
    }

    // MARK: - SSE stream

    private func openStream() async {
        // Level the store before subscribing to what happens next. The stream
        // carries only events after it opens, so anything the store is behind
        // by has to be fetched rather than waited for.
        await catchUp()
        guard running else { return }

        let cursor = try? await mutationQueue.loadSyncState(key: cursorKey)

        var query: [(String, String)] = []
        if let cursor { query.append(("updated_after", cursor)) }

        let stream = transport.eventStream(
            path: "/events",
            query: query.isEmpty ? nil : query,
            lastEventID: cursor
        )

        // Online from the moment the stream is asked for rather than from the
        // moment it closes. Everything gated on `.online` — the proactive
        // drain above all — was unreachable for as long as a stream stayed
        // open, which against a live server is the whole session, so a write
        // made while the app was running sat in the queue until something else
        // happened to it.
        //
        // The transport cannot report that the stream opened, and that is not
        // an oversight to route around here: a healthy open sends an SSE
        // comment, which the parser drops by design, so nothing reaches this
        // layer until the first real event and a quiet stream has none.
        // Assuming the open is the accurate half of the trade — being wrong
        // costs one replay attempt that fails transiently and is retried,
        // while waiting costs every write until the stream closes.
        guard running else { return }
        await connectionManager.markOnline()

        // A request to drain that arrived while the engine was coming online
        // was dropped rather than deferred: the proactive drain fires only on
        // `.online`, and everything between `start()` and this line reads
        // `.connecting`. That window is not narrow — it spans the first
        // import, which pages the whole library — so a write made as the app
        // opened lands in it and its ping is spent on a gate that refuses.
        // Ask again for anything still queued rather than leaving it to
        // whatever happens next.
        let queueIsEmpty = (try? await mutationQueue.isEmpty) ?? false
        if !queueIsEmpty { scheduleProactiveDrain() }

        var eventsConsumed = 0
        var errored = false
        var storeRefusedEvent = false
        do {
            for try await event in stream {
                guard running else { break }
                if await applyEvent(event) == .storeRefused {
                    // Stop consuming. The cursor is parked in front of this
                    // event, and every event behind it would carry the cursor
                    // past the one that never landed — the same loss, a few
                    // events later. The reconnect reopens from here.
                    storeRefusedEvent = true
                    break
                }
                eventsConsumed += 1
            }
        } catch {
            errored = true
        }

        await replayMutations()
        await suspendStreamIfNeededForTesting(at: .beforeMarkOnline)
        guard running else { return }
        await connectionManager.markOnline()
        await suspendStreamIfNeededForTesting(at: .beforeReconnectSchedule)

        // Reconnect nudge. Without this, a closed-but-not-errored SSE stream
        // (server-side idle timeout, catchup_too_old finalize, transport
        // timeout) would leave the engine parked on `.online` forever —
        // `runLoop` only re-enters `openStream` on a `.connecting` transition
        // from `NWPathMonitor`. After a brief back-off we flip
        // ConnectionStateManager back to `.connecting`, which runLoop picks
        // up and re-opens the stream. Without it the symptom is a "last
        // synced" footer frozen at the moment the stream quietly closed.
        //
        // A fast-fail (no events consumed AND either an error thrown or the
        // very first event refused by the store) stacks exponential back-off
        // to avoid hammering an unreachable server — or reopening a stream
        // once a second against a local store that cannot accept anything.
        // A healthy close (any event consumed, or clean finish) resets to
        // the base delay so SSE idle-reconnects stay snappy.
        //
        // Scheduled as a detached task — otherwise `openStream` wouldn't
        // return until the back-off elapsed, blocking `runLoop` from
        // observing state transitions (a real network drop, a manual
        // offline → connecting flip) that arrive during the wait.
        let fastFail = (eventsConsumed == 0 && (errored || storeRefusedEvent))
        if fastFail {
            consecutiveFastFailures += 1
        } else {
            consecutiveFastFailures = 0
        }
        scheduleReconnectNudge()
    }

    /// Cancels any outstanding nudge and schedules a new one. The detached
    /// task sleeps for the back-off, then flips
    /// ``ConnectionStateManager`` back to `.connecting` so `runLoop`
    /// re-opens the SSE stream. `markConnecting` is a no-op when offline,
    /// so a real network drop during the wait can't spoof us into claiming
    /// connectivity we don't have.
    private func scheduleReconnectNudge() {
        reconnectTask?.cancel()
        let delay = reconnectDelay(for: consecutiveFastFailures)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            await self?.nudgeReconnect()
        }
    }

    private func nudgeReconnect() async {
        guard running else { return }
        await connectionManager.markConnecting()
    }

    /// Back-off schedule. Healthy close (no consecutive fast-fails) uses
    /// ``reconnectBaseDelay``; fast-fails escalate exponentially and cap at
    /// ``reconnectMaxDelay``, with a ±20% jitter so coordinated client
    /// wake-ups don't pile onto the server simultaneously.
    private func reconnectDelay(for fastFailures: Int) -> TimeInterval {
        guard fastFailures > 0 else { return reconnectBaseDelay }
        let exponential = reconnectBaseDelay * pow(2.0, Double(fastFailures - 1))
        let capped = min(exponential, reconnectMaxDelay)
        return capped * Double.random(in: 0.8...1.2)
    }

    /// Counter for consecutive fast-fail reconnects. Reset on any healthy
    /// stream close (events consumed or clean finish).
    private var consecutiveFastFailures = 0

    /// Baseline delay between an SSE close and the next reconnect nudge.
    /// Internal so tests can compress the schedule. One second gives the
    /// server a breath without being user-visible.
    internal var reconnectBaseDelay: TimeInterval = 1.0

    /// Upper bound on the exponential reconnect back-off. Internal so tests
    /// can compress the schedule. Thirty seconds keeps the long tail bounded
    /// while letting a genuinely unreachable server recover without client
    /// spam.
    internal var reconnectMaxDelay: TimeInterval = 30.0

    /// Actor-isolated test seam — tests compress the reconnect back-off to
    /// milliseconds so they don't hang on the default 1–30s schedule.
    internal func setReconnectDelaysForTesting(base: TimeInterval, max: TimeInterval) {
        self.reconnectBaseDelay = base
        self.reconnectMaxDelay = max
    }

    /// Observation-only seam for deterministic stop-barrier coverage.
    internal var isStoppingForTesting: Bool {
        stoppingTask != nil
    }

    /// Observation-only seam for restart lifecycle coverage.
    internal var isRunningForTesting: Bool {
        running
    }

    internal var isStartingForTesting: Bool {
        starting
    }

    internal var isStartPublicationSuspendedForTesting: Bool {
        startPublicationContinuationForTesting != nil
    }

    internal var hasLifecycleTasksForTesting: Bool {
        hasLifecycleTasks
    }

    internal var isStreamSuspendedForTesting: Bool {
        streamSuspendContinuationForTesting != nil
    }

    internal nonisolated var eventSubscriberCountForTesting: Int {
        subscribers.withLock { $0.count }
    }

    /// Subscribes and reports the resulting count without releasing actor
    /// isolation in between. A registration routed through a task needs this
    /// actor to land, so it provably cannot interleave here — which is what
    /// makes "did `events` register before it returned?" an assertion rather
    /// than a race the caller might win.
    internal func subscribeAndCountForTesting() -> (AsyncStream<SyncEvent>, Int) {
        let stream = events
        return (stream, eventSubscriberCountForTesting)
    }

    internal func suspendStreamForTesting(at point: StreamSuspendPointForTesting) {
        streamSuspendPointForTesting = point
    }

    internal func resumeStreamForTesting() {
        streamSuspendContinuationForTesting?.resume()
        streamSuspendContinuationForTesting = nil
    }

    private func suspendStreamIfNeededForTesting(
        at point: StreamSuspendPointForTesting
    ) async {
        guard streamSuspendPointForTesting == point else { return }
        streamSuspendPointForTesting = nil
        await withCheckedContinuation { continuation in
            streamSuspendContinuationForTesting = continuation
        }
    }

    internal func suspendNextStartPublicationForTesting() {
        shouldSuspendNextStartPublicationForTesting = true
    }

    internal func resumeStartPublicationForTesting() {
        startPublicationContinuationForTesting?.resume()
        startPublicationContinuationForTesting = nil
    }

    private func suspendStartPublicationIfNeededForTesting() async {
        guard shouldSuspendNextStartPublicationForTesting else { return }
        shouldSuspendNextStartPublicationForTesting = false
        await withCheckedContinuation { continuation in
            startPublicationContinuationForTesting = continuation
        }
    }

    /// Drives replay directly without changing lifecycle state. This lets tests
    /// prove that a cancelled engine cannot stamp a clean drain before replay.
    internal func replayMutationsForTesting() async {
        await replayMutations()
    }

    // MARK: - Event application

    /// Test seam — drives `applyEvent` directly from unit tests so we can
    /// exercise reentry-sensitive branches (e.g. the `catchup_too_old`
    /// concurrency guard) that the serial SSE for-await loop can't reproduce.
    /// Not part of the public API.
    internal func _applyEventForTesting(_ event: SSEEvent) async {
        _ = await applyEvent(event)
    }

    /// What one event left behind, for ``openStream`` to act on.
    private enum EventOutcome {
        /// The cursor now covers this event. Either it was written to the
        /// local store, or there was nothing to write: an event type this
        /// version doesn't handle, or a payload that failed to decode. The
        /// latter two can never apply, so holding the cursor in front of one
        /// would wedge sync on an event that is never going to land.
        case settled

        /// The local store refused the write. The cursor still points in
        /// front of this event, so the next connection receives it again.
        case storeRefused
    }

    /// Applies one event, then records the cursor — in that order, and only
    /// if the apply succeeded.
    ///
    /// The cursor is the only durable record of how far the store has been
    /// brought forward, and a reconnect resumes strictly after it. So an event
    /// the cursor has passed is never re-sent, and stamping the cursor before
    /// the write turns any store-side failure into permanent data loss: the
    /// event is gone, and nothing is left that could ask for it again.
    private func applyEvent(_ event: SSEEvent) async -> EventOutcome {
        do {
            try await applyToLocalStore(event)
        } catch {
            logger.log.error(
                "sync.sse.apply_failed event=\(event.event ?? "-", privacy: .public) id=\(event.id ?? "-", privacy: .public) reason=\(String(describing: type(of: error)), privacy: .public)"
            )
            emit(.failed(error: error))
            return .storeRefused
        }

        if let id = event.id {
            do {
                try await mutationQueue.saveSyncState(key: cursorKey, value: id)
            } catch {
                // Failing in this direction is safe and deliberately not
                // escalated: the write landed, and every apply is an
                // idempotent upsert, so an unrecorded cursor costs one replay
                // of work already done rather than an event nobody re-sends.
                logger.log.error(
                    "sync.cursor.save_failed id=\(id, privacy: .public) reason=\(String(describing: type(of: error)), privacy: .public)"
                )
            }
        }
        return .settled
    }

    /// Writes a single decoded event into the local store. Throws whatever the
    /// store threw, which is what keeps the cursor behind the event.
    private func applyToLocalStore(_ event: SSEEvent) async throws {
        guard let eventType = event.event else { return }
        let data = event.data.data(using: .utf8) ?? Data()
        let decoder = JSONDecoder()

        switch eventType {
        case "item.created":
            if let payload = decodeOrLog(ItemEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                try await localStore.upsertItem(payload.item)
                emit(.itemCreated(id: payload.item.id))
            }

        case "item.updated", "item.restored", "item.state_changed":
            if let payload = decodeOrLog(ItemEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                try await localStore.upsertItem(payload.item)
                emit(.itemUpdated(id: payload.item.id))
            }

        case "item.deleted":
            // Server sends the deleted item with state = trashed/purged.
            if let payload = decodeOrLog(ItemEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                try await localStore.upsertItem(payload.item)
                emit(.itemDeleted(id: payload.item.id))
            }

        case "edge.created":
            if let payload = decodeOrLog(EdgeEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                try await localStore.upsertEdge(payload.edge)
                emit(.edgeCreated(id: payload.edge.id))
            }

        case "edge.deleted":
            // Edge deletes carry just the edge ID in the data envelope.
            if let payload = decodeOrLog(EdgeEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                try await localStore.deleteEdge(id: payload.edge.id)
                emit(.edgeDeleted(id: payload.edge.id))
            }

        case "metadata.changed":
            if let payload = decodeOrLog(MetadataEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                let input = MetadataInput(tags: payload.metadata.tags)
                _ = try await localStore.setMetadata(itemId: payload.itemId, input: input)
                emit(.itemUpdated(id: payload.itemId))
            }

        case "catchup_too_old":
            // Server signaled the requested Last-Event-ID is older than the
            // retention window. The stream is closed after this event; clear
            // our cursor and run a fresh full resync so the next reconnect
            // opens a stream with no cursor.
            //
            logger.log.info("sync.catchup_too_old — clearing cursor and triggering full resync")
            try? await mutationQueue.clearSyncState(key: cursorKey)
            // The same catch-up the engine runs when it comes online, forced
            // past the never-imported test because this store has imported
            // before and still needs another one. It drains before importing
            // for the same reason it always does, and two of these events
            // landing on actor reentry share one import through the slot the
            // catch-up publishes rather than racing over the store.
            if let error = await catchUp(forceImport: true) {
                if error is InitialSyncError {
                    // Distinct from a transport failure. Reaching here means a
                    // write landed between the drain and the import, so the gap
                    // persists until a later drain succeeds and something asks
                    // again.
                    logger.log.error("sync.catchup_too_old.resync_refused reason=\(String(describing: error), privacy: .public)")
                } else {
                    logger.log.error("sync.catchup_too_old.resync_failed reason=\(String(describing: type(of: error)), privacy: .public)")
                }
            }
            // SSE stream was closed by the server; outer reconnect loop will
            // reopen it with no `Last-Event-ID` header.

        default:
            break
        }
    }

    /// Serialize a thrown error into a structured-but-string-shaped
    /// representation for `PendingMutationRecord.lastError`. Preserves
    /// `MarfaError.code` / `status` / `details` so a downstream
    /// inspection (CLI surface, `PendingMutationsQuery` in the app) can
    /// recover the underlying cause without falling back to `localizedDescription`,
    /// which strips structure. Non-`MarfaError` falls through to
    /// `String(describing:)`.
    private func formatLastError(_ error: Error) -> String {
        if let marfaError = error as? MarfaError {
            var parts: [String] = [
                "code=\(marfaError.code)",
                "status=\(marfaError.status)",
                "message=\(marfaError.message)"
            ]
            if let details = marfaError.details, !details.isEmpty {
                let encoder = JSONEncoder()
                if let data = try? encoder.encode(details),
                   let json = String(data: data, encoding: .utf8) {
                    parts.append("details=\(json)")
                }
            }
            return parts.joined(separator: " ")
        }
        return String(describing: error)
    }

    /// Decode an SSE event payload, logging on failure rather than
    /// silently dropping. Returns `nil` on decode error after emitting a
    /// structured log line on the `sse` category so malformed events
    /// surface as observable signal instead of blocking sync invisibly.
    private func decodeOrLog<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        eventType: String,
        decoder: JSONDecoder
    ) -> T? {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.log.error(
                "sync.sse.decode_failed event=\(eventType, privacy: .public) type=\(String(describing: T.self), privacy: .public) reason=\(String(describing: error), privacy: .private)"
            )
            return nil
        }
    }

    // MARK: - Mutation replay

    private func replayMutations() async {
        // Overlap guard — both the SSE-close path and the
        // proactive-drain path call here. Collapse concurrent entries
        // to a single cycle rather than racing over the same records.
        if draining { return }
        draining = true
        defer { draining = false }

        // A stop can race the SSE-close path. Never inspect or stamp the
        // queue after shutdown has begun: no replay occurred in this engine
        // generation, so it cannot establish a clean drain.
        guard running else { return }

        let pending: [PendingMutationRecord]
        do {
            pending = try await mutationQueue.fetchAll()
        } catch {
            recordSyncFailure(error)
            return
        }
        guard !pending.isEmpty else {
            await recordCleanDrainIfQueueIsEmpty()
            return
        }

        await connectionManager.markSyncing()
        emit(.syncing)
        let decoder = JSONDecoder()

        // Track only transient errors for the cycle-level `.failed` emit.
        // Permanent errors (400/403/404) drop the offending record and emit
        // `.mutationDropped` — they don't mean "sync failed," they mean
        // "this mutation will never succeed, don't keep trying."
        var transientError: Error?
        var remaining = pending

        // Item IDs whose `createItem` failed transiently in this cycle.
        // Any downstream item-scoped mutation keyed on the same ID is skipped
        // for the remainder of this cycle.
        //
        // Without this guard: `deleteItem(A)` fires immediately after
        // `createItem(A)` fails transiently. The server returns 404 (the item
        // never landed), which is permanent — the record is dropped. On the
        // next cycle `createItem(A)` succeeds, leaving the server with an item
        // the client has already deleted. `pendingCreateIds` prevents that by
        // deferring all follow-on mutations until `createItem` actually lands.
        var pendingCreateIds = Set<String>()

        while !remaining.isEmpty {
            let record = remaining.removeFirst()
            guard running else { return }

            // Defer item-scoped mutations whose createItem is still pending a
            // transient retry. Replaying them now would 404 (item absent on
            // server) and produce a permanent drop before createItem has a
            // chance to succeed on the next cycle.
            if let localId = record.localId,
               record.kind != .createItem,
               pendingCreateIds.contains(localId) {
                logger.log.info(
                    "sync.mutation.deferred kind=\(record.kind.rawValue, privacy: .public) item_id=\(localId, privacy: .public) reason=pending_create"
                )
                continue
            }

            // Flip the record to `.inFlight` so any `PendingMutationsQuery`
            // subscriber sees a live transition. Best-effort — if this
            // save fails (SQLite I/O), proceed to the transport call
            // anyway; the state is observable-layer metadata, not
            // required for correct replay.
            try? await mutationQueue.markInFlight(id: record.id)

            do {
                let didRewrite = try await replayRecord(record, decoder: decoder)
                try? await mutationQueue.remove(id: record.id)
                if didRewrite {
                    // A createItem replay returned a server id that differed
                    // from the client-supplied id. The queue rows downstream
                    // of this createItem have been rewritten on disk, but
                    // our in-memory `remaining` list still carries the stale
                    // payloads — re-fetch so the next iteration uses the
                    // rewritten ids.
                    do {
                        remaining = try await mutationQueue.fetchAll()
                    } catch {
                        recordSyncFailure(error)
                        return
                    }
                }
            } catch let marfaError as MarfaError where marfaError.isPermanent {
                // Persist the dropped row + remove the live row in one
                // SQLite transaction. The dropped log is the
                // ``DroppedMutationsQuery`` source of truth; cascade
                // orphans land in the same log via
                // ``MutationQueue/dropMutationsReferencingLocalId(_:droppedAt:error:)``.
                let droppedAt = Date()
                try? await mutationQueue.recordDropped(
                    record: record,
                    droppedAt: droppedAt,
                    error: marfaError
                )
                logger.log.error(
                    "sync.mutation.dropped kind=\(record.kind.rawValue, privacy: .public) item_id=\(record.localId ?? "-", privacy: .public) attempt=\(record.attemptCount + 1, privacy: .public) status=\(marfaError.status, privacy: .public) code=\(marfaError.code, privacy: .public)"
                )
                emit(.mutationDropped(
                    kind: record.kind.rawValue,
                    itemId: record.localId,
                    attempt: record.attemptCount + 1,
                    error: marfaError
                ))

                // Cascade: if a createItem was dropped, every downstream
                // mutation keyed off its local id would 404 on replay. Drop
                // them together and purge the ghost local row so the UI
                // stops showing an item that can never sync. The cascade
                // call also persists each orphan as a
                // ``DroppedMutationModel`` row (one save) — the engine
                // emits the per-orphan event from the returned snapshot.
                if record.kind == .createItem, let localId = record.localId {
                    let cascaded = (try? await mutationQueue.dropMutationsReferencingLocalId(
                        localId,
                        droppedAt: droppedAt,
                        error: marfaError
                    )) ?? []
                    try? await localStore.purgeItem(id: localId)
                    for ghost in cascaded {
                        logger.log.error(
                            "sync.mutation.dropped.cascade parent_kind=createItem parent_local_id=\(localId, privacy: .public) kind=\(ghost.kind.rawValue, privacy: .public) local_id=\(ghost.localId ?? "-", privacy: .public)"
                        )
                        emit(.mutationDropped(
                            kind: ghost.kind.rawValue,
                            itemId: ghost.localId,
                            attempt: ghost.attemptCount + 1,
                            error: marfaError
                        ))
                    }
                    // In-memory replay list is now stale — refetch so we
                    // don't try to replay the cascade-deleted rows.
                    do {
                        remaining = try await mutationQueue.fetchAll()
                    } catch {
                        recordSyncFailure(error)
                        return
                    }
                }
            } catch {
                transientError = error
                try? await mutationQueue.recordFailure(id: record.id, error: formatLastError(error))
                logger.log.info(
                    "sync.mutation.failed kind=\(record.kind.rawValue, privacy: .public) item_id=\(record.localId ?? "-", privacy: .public) attempt=\(record.attemptCount + 1, privacy: .public) reason=\(String(describing: type(of: error)), privacy: .public)"
                )
                // A transient createItem failure means the item doesn't exist on
                // the server yet. Mark its ID so downstream mutations are skipped
                // for the rest of this cycle — they'd 404 and drop permanently
                // before createItem gets a chance to succeed on the next retry.
                if record.kind == .createItem, let localId = record.localId {
                    pendingCreateIds.insert(localId)
                }
            }
        }

        if let transientError {
            recordSyncFailure(transientError)
        } else {
            await recordCleanDrainIfQueueIsEmpty()
        }
    }

    /// Records the failure that ended a cycle — a replay that could not
    /// finish, or a catch-up import that did not land — so ``fullSyncState``
    /// reports `.failed` until the next clean drain replaces it.
    private func recordSyncFailure(_ error: Error) {
        guard running else { return }
        lastFailedError = error
        lastFailedAt = Date()
        emit(.failed(error: error))
    }

    /// Re-reads the queue after a replay cycle before claiming success. A
    /// failed storage read, shutdown, or surviving row is an unknown or
    /// incomplete state, not a clean drain.
    ///
    /// **A store that has never completed an import cannot be caught up**,
    /// whatever its queue says, and this is the one place that decides it. An
    /// empty queue on a store with nothing in it is not a device in sync; it is
    /// a device that has not started. Without this a write queued before the
    /// first start reported `.synced` from the drain that runs in front of the
    /// import — an app told it was up to date while showing an empty library —
    /// and the first `.synced` a fresh store reports is now the one its import
    /// lands.
    private func recordCleanDrainIfQueueIsEmpty() async {
        guard running else { return }
        guard await lastFullSyncAt != nil else { return }
        let queueIsEmpty: Bool
        do {
            queueIsEmpty = try await mutationQueue.isEmpty
        } catch {
            recordSyncFailure(error)
            return
        }
        guard running, queueIsEmpty else { return }
        await recordCleanDrain()
    }

    /// Centralizes the bookkeeping for a clean drain cycle: stamps the
    /// persisted `last_clean_drain_at` timestamp, clears the in-memory
    /// failure record, and emits ``SyncEvent/synced(at:)`` to subscribers
    /// (when running). ``replayMutations()`` calls this only after a fresh,
    /// successful empty-queue read, so the persisted timestamp and emitted
    /// event share the same proven completion boundary.
    private func recordCleanDrain() async {
        guard running else { return }
        let now = Date()
        let stamp = now.ISO8601Format(.init(includingFractionalSeconds: true))
        do {
            try await mutationQueue.saveSyncState(key: cleanDrainKey, value: stamp)
        } catch {
            recordSyncFailure(error)
            return
        }
        // stop() may have begun while the persistence write was in flight.
        // Do not publish a fresh clean-drain result into the stopped lifecycle.
        guard running else { return }
        lastFailedError = nil
        lastFailedAt = nil
        emit(.synced(at: now))
    }

    /// Returns `true` if the replay rewrote a local-id in the queue, signaling
    /// to the caller that the in-memory replay list is stale.
    @discardableResult
    private func replayRecord(_ record: PendingMutationRecord, decoder: JSONDecoder) async throws -> Bool {
        let data = record.payloadJson.data(using: .utf8) ?? Data()

        switch record.kind {

        case .createItem:
            let p = try decoder.decode(CreateItemPayload.self, from: data)
            let response: ItemResponse = try await transport.request(
                method: .post, path: "/items", body: p.input, query: nil
            )
            // Reconcile local-id → server-id in the local store and in any
            // dependent queued mutations. Under the current flow this branch
            // never fires — `ItemsNamespace.create` stamps the local UUIDv7
            // into `input.id` so the server echoes it back. Preserved as
            // defense against a future server-assigned-id path or direct
            // callers that bypass the namespace.
            if let localId = record.localId, localId != response.item.id {
                try await mutationQueue.rewriteLocalId(from: localId, to: response.item.id)
                try? await localStore.upsertItem(response.item)
                try? await localStore.purgeItem(id: localId)
                return true
            }
            return false

        case .updateItem:
            let p = try decoder.decode(UpdateItemPayload.self, from: data)
            // If the call site recorded a `version`, the queued mutation
            // wants conflict-aware replay — go through `handleConflictUpdate`
            // so the captured strategy is applied against any 409 the server
            // returns.
            if let v = p.version {
                let strategy = p.conflict ?? .auto
                // The per-call closure could not be written to the queue, so a
                // `.callback` replay resolves through the resolver the app
                // registered on the client. This is the write that most needs
                // it: the raced edit in synced mode is almost never the online
                // one, it is this replay against a server the app could not
                // reach at the time.
                var resolver: ConflictResolver?
                if strategy == .callback {
                    resolver = await conflictResolvers?.current()
                    guard resolver != nil else {
                        // Deliberately not `.auto`. Resolving under a strategy
                        // the caller did not choose is the defect; keeping the
                        // mutation queued costs a delay and loses nothing,
                        // and the error is non-permanent so the next drain
                        // carries it once a resolver is registered.
                        throw ConflictResolverMissingError(
                            message:
                                "Replaying an update queued with the .callback conflict strategy, but no resolver is registered on the client. The mutation stays queued; register one with client.registerConflictResolver(_:) and it replays on the next drain."
                        )
                    }
                }
                let result = try await handleConflictUpdateWithStats(
                    transport: transport,
                    itemId: p.id,
                    clientPatch: p.properties,
                    version: v,
                    strategy: strategy,
                    resolver: resolver,
                    tier: p.tier,
                    sourceId: p.sourceId
                )
                if let summary = result.mergeSummary {
                    emit(.conflictAutoMerged(payload: summary))
                }
                emit(.itemUpdated(id: p.id))
            } else {
                // No version → fast-merge path on the server. Tier and
                // source-id still travel if the call site set them.
                let body = UpdateItemBody(
                    properties: p.properties,
                    version: nil,
                    forceSnapshot: nil,
                    tier: p.tier,
                    sourceId: p.sourceId
                )
                let _: ItemResponse = try await transport.request(
                    method: .patch, path: "/items/\(p.id)", body: body, query: nil
                )
            }

        case .deleteItem:
            let p = try decoder.decode(IDPayload.self, from: data)
            let _: EmptyResponse = try await transport.request(
                method: .delete, path: "/items/\(p.id)", body: nil, query: nil
            )

        case .restoreItem:
            let p = try decoder.decode(IDPayload.self, from: data)
            let _: ItemResponse = try await transport.request(
                method: .post, path: "/items/\(p.id)/restore", body: nil, query: nil
            )

        case .transitionItem:
            let p = try decoder.decode(TransitionPayload.self, from: data)
            let body = TransitionBody(state: p.state)
            let _: ItemResponse = try await transport.request(
                method: .post, path: "/items/\(p.id)/transition", body: body, query: nil
            )

        case .purgeItem:
            let p = try decoder.decode(IDPayload.self, from: data)
            let _: EmptyResponse = try await transport.request(
                method: .delete, path: "/items/\(p.id)/purge", body: nil, query: nil
            )

        case .createEdge:
            let p = try decoder.decode(CreateEdgePayload.self, from: data)
            let body = CreateEdgeBody(
                sourceId: p.source, targetId: p.target,
                edgeType: p.edgeType, properties: p.properties
            )
            let _: EdgeResponse = try await transport.request(
                method: .post, path: "/edges", body: body, query: nil
            )

        case .updateEdge:
            let p = try decoder.decode(UpdateEdgePayload.self, from: data)
            let _: EdgeResponse = try await transport.request(
                method: .patch, path: "/edges/\(p.id)",
                body: UpdateEdgeBody(properties: p.properties), query: nil
            )

        case .deleteEdge:
            let p = try decoder.decode(IDPayload.self, from: data)
            let _: EmptyResponse = try await transport.request(
                method: .delete, path: "/edges/\(p.id)", body: nil, query: nil
            )

        case .setMetadata:
            let p = try decoder.decode(MetadataPayload.self, from: data)
            let _: MetadataResponse = try await transport.request(
                method: .put, path: "/items/\(p.itemId)/metadata", body: p.input, query: nil
            )

        case .mergeMetadata:
            let p = try decoder.decode(MetadataPayload.self, from: data)
            let _: MetadataResponse = try await transport.request(
                method: .patch, path: "/items/\(p.itemId)/metadata", body: p.input, query: nil
            )

        case .addTags:
            let p = try decoder.decode(AddTagsPayload.self, from: data)
            let body = AddTagsBody(tags: p.tags)
            let _: MetadataResponse = try await transport.request(
                method: .post, path: "/items/\(p.itemId)/tags", body: body, query: nil
            )

        case .removeTag:
            let p = try decoder.decode(RemoveTagPayload.self, from: data)
            let _: MetadataResponse = try await transport.request(
                method: .delete, path: "/items/\(p.itemId)/tags/\(p.tag)", body: nil, query: nil
            )

        case .setExtension:
            let p = try decoder.decode(SetExtensionPayload.self, from: data)
            let encoded = p.namespace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p.namespace
            let _: ExtensionsResponse = try await transport.request(
                method: .put, path: "/items/\(p.itemId)/extensions/\(encoded)",
                body: p.data, query: nil
            )

        case .deleteExtension:
            let p = try decoder.decode(DeleteExtensionPayload.self, from: data)
            let encoded = p.namespace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p.namespace
            let _: EmptyResponse = try await transport.request(
                method: .delete, path: "/items/\(p.itemId)/extensions/\(encoded)",
                body: nil, query: nil
            )

        case .uploadBlob:
            let p = try decoder.decode(UploadBlobPayload.self, from: data)

            // A read that fails and a row that is absent are different
            // answers, and collapsing them costs the only copy of the bytes.
            // The queue holds the sole record of a blob that has not reached
            // the server, so dropping on a transient store error strands the
            // reference the item already carries: it points at a blob that
            // can now never arrive, and nothing reports it.
            let storedBlob: Data?
            do {
                storedBlob = try await mutationQueue.fetchPendingBlob(hash: p.hash)
            } catch {
                let err = MarfaError(
                    code: "pending_blob_read_failed",
                    message: "Could not read pending blob data for hash \(p.hash): \(error.localizedDescription)",
                    status: 0
                )
                emit(.blobUploadFailed(hash: p.hash, error: err))
                throw err
            }

            guard let blobData = storedBlob else {
                // The store answered, and the answer was nothing. Two very
                // different situations produce that, and they are
                // indistinguishable from here, so ask the server which one
                // this is rather than guessing.
                //
                // The common one is benign: a pending blob row is deleted in
                // exactly one place, after the server accepts the bytes, so
                // enqueuing the same hash twice while offline leaves a second
                // mutation whose bytes the first drain already uploaded and
                // cleared. Treating that as a failure told applications a blob
                // was lost when it had in fact landed.
                //
                // The rare one is real loss: bytes gone from the local store
                // without ever reaching the server. Treating that as success
                // would strand a reference silently, which is worse than the
                // false alarm it replaces.
                let alreadyOnServer: Bool
                do {
                    let (_, response) = try await transport.rawRequest(
                        method: .head, path: "/blobs/\(p.hash)",
                        body: nil, contentType: nil, query: nil
                    )
                    alreadyOnServer = response.statusCode == 200
                } catch {
                    // Could not ask. Retry rather than decide.
                    let err = NetworkError(error)
                    emit(.blobUploadFailed(hash: p.hash, error: err))
                    throw err
                }

                if alreadyOnServer {
                    emit(.blobUploadCompleted(hash: p.hash))
                    return false
                }

                let err = ValidationError(
                    message: "Pending blob data missing for hash \(p.hash) and the server does not hold it; upload cannot be replayed"
                )
                emit(.blobUploadFailed(hash: p.hash, error: err))
                throw err
            }

            let total = Int64(blobData.count)
            emit(.blobUploadStarted(hash: p.hash, totalBytes: total))

            // Capture `self` weakly in the progress closure — SyncEngine is
            // long-lived but the closure runs off `URLSession`'s delegate
            // queue, so we hop back onto the actor to emit events safely.
            let hashCopy = p.hash
            let totalCopy = total
            let (responseData, response): (Data, HTTPURLResponse)
            do {
                (responseData, response) = try await transport.rawUpload(
                    method: .post, path: "/blobs", body: blobData,
                    contentType: p.mimeType, query: nil,
                    onBytesSent: { [weak self] sent, _ in
                        Task { [weak self] in
                            await self?.emitBlobProgress(
                                hash: hashCopy,
                                bytesUploaded: sent,
                                totalBytes: totalCopy
                            )
                        }
                    }
                )
            } catch let error as MarfaError {
                emit(.blobUploadFailed(hash: p.hash, error: error))
                throw error
            } catch {
                let wrapped = NetworkError(error)
                emit(.blobUploadFailed(hash: p.hash, error: wrapped))
                throw wrapped
            }

            guard (200..<300).contains(response.statusCode) else {
                let err = parseMarfaError(data: responseData, statusCode: response.statusCode)
                emit(.blobUploadFailed(hash: p.hash, error: err))
                throw err
            }

            // Upload succeeded — clean up the stored bytes. The response
            // hash should match the locally-computed hash (same data, same
            // SHA-256); if it doesn't, the local hash was wrong and any
            // items/edges created against it will 404 on blob fetch. Log
            // but don't fail — the blob IS on the server.
            if let uploaded = try? JSONDecoder().decode(BlobUploadResponse.self, from: responseData),
               uploaded.hash != p.hash {
                logger.log.error(
                    "sync.uploadBlob.hash_mismatch local=\(p.hash, privacy: .public) server=\(uploaded.hash, privacy: .public)"
                )
            }
            try? await mutationQueue.deletePendingBlob(hash: p.hash)
            emit(.blobUploadCompleted(hash: p.hash))

        case .bulk:
            let p = try decoder.decode(BulkPayload.self, from: data)
            let _: BulkResult = try await transport.request(
                method: .post, path: "/items/bulk", body: p.input, query: nil
            )

        case .bulkAction:
            let p = try decoder.decode(BulkActionPayload.self, from: data)
            // The server returns 202 + a BulkActionJob envelope for non-dry-run
            // bulk_action. Replay is considered settled only when the server-side
            // job reaches a terminal status — `BulkActionRunner.runToCompletion`
            // polls and resolves with the unwrapped result (or throws on
            // cancelled / failed). Synced-mode replays never set `dry_run: true`
            // (dry-runs aren't enqueued in the first place), so the inline-200
            // fork is unreachable here.
            _ = try await BulkActionRunner.runToCompletion(
                transport: transport,
                input: p.input
            )

        case .bulkEdges:
            let p = try decoder.decode(BulkEdgesPayload.self, from: data)
            let _: BulkEdgeResult = try await transport.request(
                method: .post, path: "/edges/bulk", body: p.input, query: nil
            )
        }

        return false
    }
}
