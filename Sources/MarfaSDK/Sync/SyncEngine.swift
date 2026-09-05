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
    let item: Item
    // Optional because the server's envelope makes it so: the metadata key is
    // spread in only when the event carries a row. Requiring it here would put
    // a publisher that ever omits it straight back to a frame that fails to
    // decode and is dropped in silence, which is the defect this decoder
    // already had once.
    let metadata: Metadata?
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
///    `item.state_changed`, `edge.created`, `edge.updated`, `edge.deleted`,
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

    /// Set when the store this engine writes to had to be rebuilt on open.
    /// Announced once on ``start()`` and then cleared, because a restart is
    /// not a second incident.
    private var pendingStoreRecovery: StoreRecovery?

    /// Debounce window between a `MutationQueue.drainRequests` ping and
    /// the proactive drain firing. Coalesces bursts of enqueues from a
    /// single user action (e.g. `setMetadata` + `addTags` back-to-back)
    /// into one replay cycle. Default 150 ms — long enough to gather a
    /// typed burst, short enough to feel instant.
    private let drainDebounceInterval: Duration

    /// How many times a replay failure that is neither permanent nor
    /// self-evidently unresolvable is retried before the row is blocked.
    /// Network-class failures are exempt and never counted — see
    /// ``PendingMutationBlockReason/classify(error:kind:attemptCount:ceiling:)``.
    private let maxReplayAttempts: Int

    /// Whether this engine's client holds its store's writer lock.
    ///
    /// **A second engine over one store is what this refuses**, and refusing
    /// it here rather than at the queue is deliberate: the damage is not one
    /// bad write, it is two engines each holding an event cursor and each
    /// believing it is the one draining. Half the writes replay twice and the
    /// cursors diverge, which no per-statement guard can see.
    private let isStoreWriter: Bool

    // MARK: - Internals

    private var streamTask: Task<Void, Never>?
    private var stoppingTask: Task<Void, Never>?
    private var running = false

    /// Event types this build met and had no case for. The `default` arm logs
    /// each one; this is the same signal in a form a test can assert on,
    /// because a log line is not one.
    private var unhandledEventTypes: Set<String> = []
    internal var unhandledEventTypesForTesting: Set<String> { unhandledEventTypes }

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

    /// Set when a drain request arrives while a cycle is already running, and
    /// consumed by ``fireProactiveDrain()`` to run one more cycle once that one
    /// ends. Without it such a request is simply lost.
    private var drainRequestedDuringCycle = false

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

    // MARK: - Rule 19, the engine reports itself

    /// Whether the engine can currently reach the server.
    ///
    /// **Forwarded rather than left to the caller to have kept.** An app had
    /// to hold on to the ``ConnectionStateManager`` it passed into the synced
    /// factory in order to answer this, which meant every consumer inventing
    /// the same piece of plumbing to reach a value the engine already had.
    public nonisolated var connectionState: ConnectionState {
        connectionManager.state
    }

    /// The current state, then every change to it.
    ///
    /// Yields immediately so a view has something to render on first draw,
    /// rather than an empty state until the connection next changes — which,
    /// on a device that is simply online, may be never.
    public nonisolated var connectionStateUpdates: AsyncStream<ConnectionState> {
        connectionManager.stateUpdates
    }

    /// The engine's account of itself: connection, outbox, last clean drain
    /// and hydration progress.
    ///
    /// **Assembled on demand rather than cached**, so it cannot drift from the
    /// store it describes. The cost is four counts and one lookup against the
    /// database, which is cheaper than the arrays a caller would otherwise
    /// fetch and measure.
    ///
    /// **The queue's four counts and its last clean drain come off the queue
    /// actor together**, because reading them separately leaves a suspension
    /// between them and a drain landing inside it reports work outstanding
    /// beside a timestamp saying the queue had just emptied — a pair the
    /// system was never in. Connection and hydration are read after that call
    /// and are therefore the fresher two; hydration is this actor's own state,
    /// and connection is a synchronous read of the manager's mutex rather than
    /// another hop.
    /// **Throws rather than defaulting when the queue cannot be read.** A
    /// store that will not answer is not a store with nothing in it, and
    /// returning zeroes would report `isSettled` — a green tick from a
    /// measurement that failed. That is the same claim `MarfaClient/syncStatus`
    /// returns `nil` to avoid making for a client with no engine, and it would
    /// be worse here, because there *is* a queue and its contents are unknown
    /// rather than absent.
    public var status: SyncStatus {
        get async throws {
            let (queue, drainStamp) = try await mutationQueue.countsAndSyncState(
                key: cleanDrainKey
            )
            return SyncStatus(
                connection: connectionManager.state,
                queue: queue,
                lastCleanDrainAt: Self.parseDrainStamp(drainStamp),
                hydration: hydrationProgress
            )
        }
    }

    /// ISO 8601 with fractional seconds, or `nil` for absent or unparseable.
    /// Shared by ``status`` and ``lastCleanDrainAt`` so the two cannot come to
    /// different conclusions about the same stored string.
    private static func parseDrainStamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
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
            Self.parseDrainStamp(try? await mutationQueue.loadSyncState(key: cleanDrainKey))
        }
    }

    /// Point-in-time read of the engine's ``FullSyncState``.
    ///
    /// Order of precedence:
    /// 1. ``FullSyncState/syncing`` if a drain cycle is currently in flight.
    /// 2. ``FullSyncState/parked(reason:count:)`` if the queue has stopped on
    ///    a refused credential.
    /// 3. ``FullSyncState/failed(at:error:)`` if the most recent cycle
    ///    bailed and no later clean drain has cleared it.
    /// 4. ``FullSyncState/synced(at:)`` if a clean drain timestamp is
    ///    persisted.
    /// 5. ``FullSyncState/notYetSynced`` otherwise.
    ///
    /// A queue that cannot be read reports ``FullSyncState/failed(at:error:)``
    /// rather than falling through, for the reason ``status`` gives: a store
    /// that will not answer is not a store with nothing in it.
    ///
    /// **The park is read here and not only written.** Suppressing the clean
    /// drain stops a *new* timestamp being stamped and does nothing about the
    /// one already there, so a store that synced before the credential died
    /// went on answering `.synced(at:)` from it — and a transient failure
    /// recorded before the parking would otherwise stand for ever, because a
    /// clean drain is the only thing that clears one and a parked queue cannot
    /// produce a clean drain.
    ///
    /// ``MarfaStore/queryFullSyncState()`` returns a reactive
    /// `@Observable` view backed by the same signals; prefer that for
    /// SwiftUI views.
    public var fullSyncState: FullSyncState {
        get async {
            if draining { return .syncing }
            // **One read, and a store that will not answer says so.** `status`
            // states both rules about itself seventy lines up: it takes the
            // counts and the drain stamp together because a park landing
            // between two reads yields a green tick over a parked queue, and it
            // throws rather than defaulting because a store that will not
            // answer is not a store with nothing in it. This cannot throw
            // without a source break, so it reports the failure instead.
            let counts: MutationQueueCounts
            let drainStamp: String?
            do {
                (counts, drainStamp) = try await mutationQueue.countsAndSyncState(
                    key: cleanDrainKey
                )
            } catch {
                return .failed(at: Date(), error: error)
            }
            if let parked = counts.blocked[.credentialRefused], parked > 0 {
                return .parked(reason: .credentialRefused, count: parked)
            }
            if let err = lastFailedError, let at = lastFailedAt {
                return .failed(at: at, error: err)
            }
            if let stamped = Self.parseDrainStamp(drainStamp) {
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
        conflictResolvers: ConflictResolverRegistry? = nil,
        maxReplayAttempts: Int = 5,
        storeRecovery: StoreRecovery? = nil,
        /// Defaults to `true`, so an engine built directly — every test
        /// fixture, and any consumer assembling one itself — keeps writing.
        /// `MarfaClient.synced` is the door that takes a real lock and passes
        /// what it got; nothing else can know.
        isStoreWriter: Bool = true
    ) {
        self.transport = transport
        self.localStore = localStore
        self.mutationQueue = mutationQueue
        self.connectionManager = connectionManager
        self.drainDebounceInterval = drainDebounceInterval
        self.conflictResolvers = conflictResolvers
        self.pendingStoreRecovery = storeRecovery
        // A ceiling below one would block a write on its first failure,
        // including the network-class failures that are meant to be exempt —
        // an offline device would park every write it made.
        precondition(maxReplayAttempts >= 1, "maxReplayAttempts must be at least 1")
        self.maxReplayAttempts = maxReplayAttempts
        self.isStoreWriter = isStoreWriter
    }

    // MARK: - Blocked mutations

    /// Returns a blocked mutation to the queue and asks for a drain.
    ///
    /// The block goes and the attempt count starts again, so a row blocked by
    /// ``PendingMutationBlockReason/conflictUnresolved`` or
    /// ``PendingMutationBlockReason/retriesExhausted`` replays once the app has
    /// dealt with whatever stopped it. A
    /// ``PendingMutationBlockReason/resolverMissing`` block needs no call —
    /// registering a resolver is enough, and the next drain carries it.
    ///
    /// Calling this on a row that is not blocked resets its attempt count and
    /// asks for a drain, which is what the name promises and costs nothing. An
    /// id the queue does not hold is a no-op, matching every other id-addressed
    /// call on the queue.
    public func retry(id: String) async throws {
        try await mutationQueue.clearBlock(id: id)
        // `clearBlock` pings the drain-request stream, and that ping is enough
        // only when a listener is attached and idle. Ask here as well, so the
        // promise this method's name makes does not depend on either: a cycle
        // already running takes the row on the pass that follows it, and an
        // idle engine schedules one through the ordinary debounce rather than
        // blocking the caller for a whole drain.
        if draining {
            drainRequestedDuringCycle = true
        } else {
            scheduleProactiveDrain()
        }
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
        // **A client that does not hold its store's writer lock does not
        // sync.** Somebody else's engine is draining this queue and holding
        // this cursor; a second one would replay half the writes twice and
        // leave the two cursors disagreeing about what has been seen. Logged
        // at error rather than thrown, because this is a supported
        // arrangement — an app and its share extension both open the store,
        // and only one of them should be the engine.
        guard isStoreWriter else {
            logger.log.error(
                "sync.start.refused reason=not_store_writer — another client holds this store's writer lock, so this one reads and does not drain"
            )
            return
        }
        while let stoppingTask {
            await stoppingTask.value
            // The stop owner clears `stoppingTask` after observing the same
            // barrier. Yield so a resumed start cannot publish a new
            // generation while that owner still considers stop in progress.
            await Task.yield()
        }
        guard !running, !starting else { return }
        // Before anything that can suspend. The store was opened long before
        // this engine existed, so this is the first moment there is anywhere
        // to say what happened to it, and a subscriber who took the stream and
        // then called `start()` must not be able to miss it.
        if let recovery = pendingStoreRecovery {
            pendingStoreRecovery = nil
            emit(.storeRecovered(recovery))
        }
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
    /// Safe to call repeatedly — `upsertItem`, `upsertMetadata` and
    /// `upsertEdge` are all idempotent.
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
    /// owner and joiners alike.
    ///
    /// A test proving that two callers share one import has to know both have
    /// arrived before it releases the first, and every other way of knowing
    /// that is a sleep racing the thing it measures.
    internal private(set) var importCallerCount = 0


    @discardableResult
    public func performInitialSync(pageSize: Int = 200) async throws -> Int {
        // **Gated for the same reason `start()` is, and the gate on `start()`
        // alone was not enough.** An import is not only reads: it upserts
        // items, edges and metadata, and it *prunes* — it takes the ids the
        // server returned as the whole answer and removes the rest. A client
        // that does not hold the store's writer lock running that can delete
        // rows the real writer created locally and has not yet pushed.
        //
        // Thrown rather than logged, because this one has a caller who asked
        // for it and is waiting on a count. `start()` is the engine's own
        // lifecycle and has nobody to tell.
        guard isStoreWriter else {
            throw LocalStoreError.storeQuarantineFailed(
                "this client does not hold the store's writer lock, so it cannot import — another client is the writer for this store"
            )
        }
        importCallerCount += 1
        defer { importCallerCount -= 1 }

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
            // A joiner does **not** cancel the import when it is cancelled
            // itself. The task belongs to the caller that started it, and
            // abandoning that caller's work because a later arrival went away
            // is the opposite of what coalescing is for. The cost is stated
            // rather than hidden: a cancelled joiner keeps waiting, because
            // `await` on another task's value cannot be interrupted without
            // cancelling it. Closing that needs joiners to observe completion
            // through something they can be released from, which is a larger
            // change than this one.
            return try await importTask.value
        }
        let task = Task { [self] in
            try await refuseIfWorkIsStillQueued()
            return try await importPasses(pageSize: pageSize)
        }
        importTask = task
        defer { if importTask == task { importTask = nil } }
        // The owner forwards its cancellation, which nothing here used to do.
        // An unstructured task inherits none from whoever awaits it, so a
        // cancelled caller stayed suspended on a value that would never
        // arrive — and because the inner task was never cancelled, neither was
        // anything it awaited, so a transport holding a request open never
        // learned to let go either. `stop()` has always cancelled-then-awaited
        // its lifecycle tasks; this was the one place on this path that did
        // neither.
        //
        // **And it cancels unconditionally, which costs a joiner its import.**
        // `task.value` rethrows the child's error, so a cancelled owner hands
        // `CancellationError` to everyone joined to it — none of them
        // cancelled, none consulted, and the owner is only whoever arrived
        // first. Making the cancel conditional on there being no joiners was
        // tried and is worse: it protects the joiners and strands the owner,
        // which cannot abandon `task.value` any more than a joiner can.
        //
        // Both halves have the same root, and one fix answers both: waiters
        // registering their own continuations, so any of them can be released
        // without touching the shared task, which is the shape the blocking
        // transports in the test support already use. That is a restructure of
        // this function rather than a line in it, so the cost is recorded here
        // and carried rather than swapped for a different one.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Refuses the import while the queue still holds work, rather than
    /// overwriting it. Every row the import receives goes through
    /// `upsertItem`, which replaces all of an item's columns with no version
    /// check, and `upsertMetadata`, which replaces the whole metadata row.
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
    /// Per-row skipping was the other option and it still cannot be made
    /// complete, though the reason has narrowed. A mutation carries an
    /// optional `localId` and the bulk enqueues set none, so a per-row test
    /// has to read payloads: `pendingItemEdits` now does that for `bulk`,
    /// whose entries name their ids. `bulkAction` selects by a filter
    /// expression rather than by id, so no payload read can answer "does this
    /// name item X" without evaluating the server's filter grammar locally —
    /// which is why the whole-queue count, not a per-row test, is what gates
    /// the import.
    ///
    /// The engine's own catch-up drains before it asks, which is what clears
    /// the way rather than working around this.
    private func refuseIfWorkIsStillQueued() async throws {
        let pending = try await mutationQueue.pendingCount
        if pending > 0 {
            throw InitialSyncError.pendingMutations(count: pending)
        }
    }

    /// The most recent hydration progress, or `nil` if no import has run in
    /// this process. Read by ``status``.
    private(set) var hydrationProgress: HydrationProgress?

    /// The server's own count of what it holds, summed across states because
    /// the import reads every state.
    private func statsTotal() async throws -> Int? {
        let stats: [String: Int] = try await transport.request(
            method: .get, path: "/items/stats", body: nil, query: nil
        )
        // An empty answer is not a total of zero — it is a route that told us
        // nothing, and showing "0 of 0" while rows arrive is worse than
        // showing no bar at all.
        return stats.isEmpty ? nil : stats.values.reduce(0, +)
    }

    /// The import itself, with no refusal and no coalescing — both belong to
    /// the callers above, which is what lets the catch-up drain first and then
    /// reach the same passes an explicit caller reaches.
    private func importPasses(pageSize: Int) async throws -> Int {
        var cursor: String? = nil
        var imported = 0

        // **The denominator is bought only when it is worth buying**, which is
        // after the first page says there is more. A page-based import knows
        // what it has taken and nothing about what is left, so progress from
        // pages alone is a guess that reaches nine tenths and stays there —
        // and `GET /items/stats` answers with a count per state, which summed
        // is the figure to show against because this import reads every state.
        //
        // Deferring it costs nothing and saves a request on every import that
        // fits in one page, which is most of them and all the small ones. A
        // progress bar for twenty rows is not worth a round trip, and the
        // import that needs one is by definition the import with pages left to
        // pay for it.
        //
        // Best effort either way: a space that will not answer this is a space
        // that can still be imported, so progress is reported as absent rather
        // than as a wrong number.
        // **Cleared at the top, so a later import never reports an earlier
        // one's numbers.** Without this a re-import that fits in one page
        // leaves the previous fill's figures standing.
        hydrationProgress = nil

        // **And cleared again on the way out if this import did not finish.**
        // The reset above was written as though it covered that too, and it
        // does not: it only protects the *next* import, and an import that
        // throws on page four may have no next one. What stands until the
        // process ends is a fraction frozen partway, which is the one thing a
        // progress bar must never show — indistinguishable from a fill still
        // running. A cancellation lands here as well, which is right: a
        // stopped engine is not a hydrating one.
        var finished = false
        // **Both surfaces, or the push surface is left saying the opposite of
        // the pull surface.** Clearing `hydrationProgress` fixes what `status`
        // reports and nothing else: a consumer drawing a bar from
        // `hydrationProgress` events — which is the surface documented for
        // drawing one — has been told 2 of 10 and is never told anything after
        // it.
        defer {
            if !finished {
                hydrationProgress = nil
                emit(.hydrationEnded(imported: imported, completed: false))
            }
        }

        // **Asked at most once, whatever the answer.** `total == nil` looks
        // like it says that and does not: a route that answers `{}` or fails
        // leaves `total` nil, so the condition is true again on the next page,
        // and a twenty-page import against a space whose stats route is down
        // asks nineteen times. The flag records that the question was put,
        // which is the thing being paid for.
        //
        // **What that gives up, said rather than left to be discovered:** a
        // stats route that fails once transiently is not asked again, so an
        // import that would have got a denominator on page two now runs to the
        // end without one and reports no progress at all. That is the right
        // trade — a bar is not worth nineteen round trips against a route that
        // is down — but it is a trade rather than a free saving.
        var askedForTotal = false
        var total: Int?
        // Every id the answer mentioned. What the prune below is for: a row the
        // server purged while this device was away is absent from the answer
        // rather than changed in it, so no event describes it and nothing else
        // ever corrects it.
        var seenItemIds: Set<String> = []
        repeat {
            // `stop()` cancels this task, and a page loop that never asks
            // would keep paging a whole library past the teardown that was
            // meant to end it.
            try Task.checkCancellation()
            var query: [(String, String)] = [
                ("limit", String(pageSize)),
                // `system` beside `metadata`, and the prune is why. `GET /items`
                // leaves `system.*` rows out unless a caller asks for them, so
                // an import that does not ask sees none of them — while the
                // stream, which filters on nothing, has been writing them to
                // this store all along. The keep-set would then omit every
                // device, connection and activity row the store holds, and the
                // prune would delete the lot: `connections.list()` empties while
                // the server still has all of them, and no event ever corrects
                // it, because no event describes a row that did not change.
                //
                // Widening the question is the fix rather than teaching the
                // prune to skip these rows, because the prune's whole premise is
                // that the answer is the entire server side. A carve-out there
                // would keep a genuinely purged connection on the device
                // forever, and would sit in a function that cannot see which
                // query produced its keep-set.
                ("include", "metadata,system"),
                // Every state, trashed included. Omitted, the route answers
                // with active rows only, and reading that as the whole library
                // would make every row in the bin look purged — so the prune
                // below would empty the device's bin on each re-import. It is
                // also what brings a row *into* the bin on a device that was
                // away when it was trashed.
                ("state", "any"),
            ]
            if let cursor { query.append(("cursor", cursor)) }

            let page: PaginatedResult<ItemWithMetadata> = try await transport.request(
                method: .get, path: "/items", body: nil, query: query
            )

            for pair in page.data {
                try await localStore.upsertItem(pair.item)
                try await localStore.upsertMetadata(pair.metadata)
                seenItemIds.insert(pair.item.id)
                imported += 1
            }

            // Asked for once, on learning the import will not fit in a page.
            if !askedForTotal, page.hasMore {
                askedForTotal = true
                total = try? await statsTotal()
            }

            // Once per page, not once per row. A progress event per item on a
            // ten-thousand-row import is ten thousand main-actor hops to move
            // a bar by a pixel.
            if let total {
                hydrationProgress = HydrationProgress(imported: imported, total: total)
                emit(.hydrationProgress(imported: imported, total: total))
            }

            if !page.hasMore {
                break
            }
            // The server said there is more and did not say where to resume
            // from. Refused rather than treated as the end, because the prune
            // below reads `seenItemIds` as the whole server side: exiting here
            // would hand it a keep-set holding only the pages that arrived, and
            // every row on every page that did not would be deleted as purged.
            //
            // The loop used to end on exactly this pair by accident — a null
            // cursor failed the `while` condition one line down and returned
            // normally. The current server cannot produce it, since its item
            // store only sets a cursor when there is more; this kit ships
            // against self-hosted servers, so that is a fact about one
            // implementation rather than a guarantee of the route.
            guard let nextCursor = page.cursor else {
                throw InitialSyncError.unresumablePage(route: "/items", imported: imported)
            }
            cursor = nextCursor
            // Not `while cursor != nil`: the guard above has already settled
            // that, and a condition that can no longer be false is the one that
            // hid this. The two ways out are the `break` and the `throw`.
        } while true

        // The queue is asked here rather than before the first page, and the
        // difference is the whole point. `refuseIfWorkIsStillQueued` runs once,
        // ahead of the import, so what it guarantees is that nothing was queued
        // when the import *began* — and the paging that follows spans a whole
        // library. Someone writing a note while theirs downloads lands inside
        // that window, and the row the server has never heard of is exactly the
        // one this pass would otherwise take for a purge.
        //
        // Thrown rather than defaulted when the queue cannot be read. An empty
        // answer here is indistinguishable from "protect nothing", and pruning
        // on it would delete the rows this list exists to keep. Failing leaves
        // the store as it was and the next cycle asks again.
        let protectedIds = try await mutationQueue.pendingCreatedItemIds()
        let removed = try await localStore.pruneItems(
            keeping: seenItemIds, protecting: protectedIds
        )
        for id in removed {
            emit(.itemPurged(id: id))
        }

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
            // Same refusal as the item loop, for a smaller consequence: edges
            // are never pruned, so a short read here loses no row — it leaves
            // the device holding a library with relationships missing, which
            // reads to a person as notes that have quietly stopped being
            // related to each other. Worth a legible failure rather than a
            // silent one either way, and leaving the shape here while fixing it
            // above would leave the next reader to work out which of the two
            // loops was the deliberate one.
            guard let nextEdgeCursor = page.cursor else {
                throw InitialSyncError.unresumablePage(route: "/edges", imported: edgesImported)
            }
            edgeCursor = nextEdgeCursor
        } while true

        logger.log.info(
            "sync.initial_sync items=\(imported, privacy: .public) edges=\(edgesImported, privacy: .public) pruned=\(removed.count, privacy: .public)"
        )

        // Stamp the completion so consumers can gate fresh pulls on recency
        // rather than "is the local store empty?". Uses the same ISO 8601
        // with fractional seconds as the mutation queue's created_at for
        // consistency and to stay off the non-Sendable `ISO8601DateFormatter`.
        let stamp = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        try? await mutationQueue.saveSyncState(key: fullSyncKey, value: stamp)

        // Everything that could throw is behind us, so the figures this import
        // reported are a finished account rather than a stalled one.
        finished = true
        emit(.hydrationEnded(imported: imported, completed: true))
        return imported
    }

    /// Releases every mutation parked under one reason, and only that one.
    ///
    /// **By reason rather than wholesale, because what clears each differs.** A
    /// working credential releases everything parked on the old one; it settles
    /// nothing about a conflict awaiting review, and sweeping those up would
    /// spend a request re-parking each of them while telling an app they were
    /// moving again.
    ///
    /// Returns how many were released. The next drain sends them.
    @discardableResult
    public func retryAll(reason: PendingMutationBlockReason) async throws -> Int {
        let released = try await mutationQueue.retryAll(reason: reason)
        guard released > 0 else { return 0 }
        logger.log.info(
            "sync.queue.released reason=\(reason.rawValue, privacy: .public) count=\(released, privacy: .public)"
        )
        // **Releasing is not sending, and this method's name promises the
        // second.** `retry(id:)` says why the queue's own ping is not enough on
        // its own — it needs a listener attached and idle — and the same holds
        // here. The two cover different conditions: the ping wakes an idle
        // engine, and this takes the pass after a cycle that is already
        // running.
        if draining {
            drainRequestedDuringCycle = true
        } else {
            scheduleProactiveDrain()
        }
        // **And say that the park is over.** Nothing else does: the drain
        // scheduled above may not run for a long time — the device may be
        // offline — and a consumer folding events would sit on `.parked` while
        // the credential that caused it has been replaced, telling somebody who
        // has just signed in to sign in again. `.syncing` is the honest word
        // for it: the work has been released and is on its way.
        //
        // **Keyed on the reason rather than on the total, which is what this
        // was first written as and is wrong in two directions.** A queue can
        // hold a conflict awaiting review alongside the credential park —
        // `parkAllLive` leaves an already-blocked row on its own reason, by
        // design — so a total that is still non-zero would withhold the
        // announcement for a park that really is over. And releasing some
        // *other* reason on a queue that was never parked would announce a
        // release of something that never happened, moving an app off a
        // `.synced` that was correct.
        if reason == .credentialRefused,
            ((try? await mutationQueue.counts.blocked[.credentialRefused]) ?? nil) == nil
        {
            emit(.syncing)
        }
        return released
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
    /// What a catch-up did, which is three answers rather than two.
    ///
    /// **`skipped` and `failed` are not the same and one caller has to tell
    /// them apart.** A catch-up that declined to import — because the queue
    /// has not drained — left the store exactly as it was, so anything the
    /// caller did *in anticipation* of the import is now a lie. The
    /// `catchup_too_old` handler is that caller: it used to clear the event
    /// cursor first and ask afterwards, which is fine when a refusal is rare
    /// and permanent when a queue can stay undrained for a week.
    enum CatchUpOutcome {
        case imported
        case skipped
        case failed(Error)
    }

    @discardableResult
    private func catchUp(forceImport: Bool = false) async -> CatchUpOutcome {
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
                return .skipped
            }
        }

        let hasImported = await lastFullSyncAt != nil
        guard forceImport || !hasImported else { return .skipped }

        do {
            _ = try await performInitialSync()
            // The queue is empty and the library is level, which is what a
            // clean drain already means; this is the existing check, asked at
            // one more point rather than a second definition. Without it the
            // state would sit at `.notYetSynced` until something closed the
            // stream, and against a live server nothing does.
            await recordCleanDrainIfQueueIsEmpty()
            return .imported
        } catch {
            // Recorded and left visible rather than escalated. The caller
            // opens the stream after this returns either way: a device whose
            // import failed should not also be deaf to what happens next, and
            // the next online cycle asks again because the import stamped
            // nothing. Returned as well as recorded so a caller with more
            // context than this can say where it happened.
            recordSyncFailure(error)
            return .failed(error)
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
        guard running else { return }
        guard !draining else {
            // A request arriving while a cycle is running used to be dropped,
            // so a write enqueued mid-drain waited for an unrelated wake-up —
            // the next enqueue, a network transition, or a stream close that a
            // live server never delivers. Remember it and run one more cycle
            // when this one ends. `SyncEngine.retry(id:)` promises a drain, and
            // an app calling it while the engine happens to be busy is the
            // likeliest moment for it to be called at all.
            drainRequestedDuringCycle = true
            return
        }
        let state = connectionManager.state
        guard state == .online else { return }
        // Each extra pass runs only because a request arrived during the one
        // before it, so this drains a burst rather than spinning.
        repeat {
            drainRequestedDuringCycle = false
            await replayMutations()
        } while drainRequestedDuringCycle && running
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

    /// Writes an item the server described into the local store, as what an
    /// app should see rather than as the server's copy verbatim.
    ///
    /// Every item-shaped frame goes through here — including the one
    /// `metadata.changed` carries — so a device holding an unsent edit shows
    /// the same thing whichever frame arrives.
    ///
    /// Returns whether the store took the frame. Callers announce only on
    /// `true`, and that is the whole reason this hands the answer back rather
    /// than swallowing it into a log line: a refused frame changed nothing, so
    /// an event describing it tells an app the opposite of what the store
    /// holds. A stale `item.deleted` is the case that bites — the row is
    /// correctly left active, and an ungated emit hands the app
    /// `.itemDeleted(id:)` for a row it can still read.
    private func applyInboundItem(_ item: Item) async throws -> Bool {
        // Keyed on `localId` for the four single-item kinds, plus every
        // queued `bulk` row — those carry no `localId`, so they are fetched by
        // kind and filtered on their entries here. A device with nothing
        // queued is the ordinary case and the fetch returns nothing; a device
        // holding bulk writes pays for reading them on each inbound frame,
        // which is the cost of the rebase seeing them at all.
        let edits = try await mutationQueue.pendingItemEdits(forItem: item.id)
        let applied = try await localStore.applyServerItem(item, rebasing: edits)
        if !applied {
            logger.log.info(
                "sync.sse.stale_item_frame id=\(item.id, privacy: .public) version=\(item.version, privacy: .public)"
            )
        }
        return applied
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
                if try await applyInboundItem(payload.item) {
                    emit(.itemCreated(id: payload.item.id))
                }
            }

        case "item.updated", "item.restored", "item.state_changed":
            if let payload = decodeOrLog(ItemEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                if try await applyInboundItem(payload.item) {
                    emit(.itemUpdated(id: payload.item.id))
                }
            }

        case "item.deleted":
            // Server sends the deleted item with state = trashed.
            if let payload = decodeOrLog(ItemEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                if try await applyInboundItem(payload.item) {
                    emit(.itemDeleted(id: payload.item.id))
                }
            }

        case "item.purged":
            // Not the same news as `item.deleted`. That one says the row was
            // trashed and can come back, so a store that keeps trash keeps it;
            // this one says the row is gone for good and nothing will ever
            // correct a copy of it. The frame still carries the row as it last
            // stood, because there is nothing left to read once it has been
            // published.
            //
            // No rebase and no version check: a queued edit against a row the
            // server no longer has cannot land whatever this device does with
            // it, and keeping the row so the edit stays visible would leave
            // someone looking at something that does not exist.
            if let payload = decodeOrLog(ItemEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                try await localStore.purgeItem(id: payload.item.id)
                emit(.itemPurged(id: payload.item.id))
            }

        case "edge.created":
            if let payload = decodeOrLog(EdgeEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                try await localStore.upsertEdge(payload.edge)
                emit(.edgeCreated(id: payload.edge.id))
            }

        case "edge.updated":
            // Same envelope as `edge.created`, carrying the whole edge rather
            // than the fields that moved, so the upsert is the apply. It also
            // stores an edge this device has never seen: the create can have
            // landed before this cursor, which makes the edit the first
            // mention of it, and dropping the frame would leave the
            // relationship missing until the next import.
            if let payload = decodeOrLog(EdgeEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                try await localStore.upsertEdge(payload.edge)
                emit(.edgeUpdated(id: payload.edge.id))
            }

        case "edge.deleted":
            // Edge deletes carry just the edge ID in the data envelope.
            if let payload = decodeOrLog(EdgeEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                try await localStore.deleteEdge(id: payload.edge.id)
                emit(.edgeDeleted(id: payload.edge.id))
            }

        case "metadata.changed":
            if let payload = decodeOrLog(MetadataEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                // The item first, and not only for completeness: a metadata
                // row is attached to its item when it is written, so storing
                // the sidecar for an item this device has never seen would
                // orphan it — present in the store, absent from every read
                // that reaches it through the item. A tag on another device
                // is reason enough for this frame to be the first mention of
                // an item created before this device's cursor.
                //
                // The item is applied on every such frame rather than only an
                // unknown one, and through the same path `item.updated` takes:
                // it carries the same exposure to a queued local edit, so it
                // needs the same rebase rather than a second answer to it.
                //
                // The two halves are judged separately, which is the one place
                // that matters. The item half can be refused for naming a
                // version the row has already passed; the sidecar is a
                // different layer with its own announcement and is not stale
                // because the item half was. Gating the metadata write on the
                // item's answer would silently drop a tag another device really
                // did add.
                let itemApplied = try await applyInboundItem(payload.item)
                var metadataApplied = false
                if let metadata = payload.metadata {
                    try await localStore.upsertMetadata(metadata)
                    metadataApplied = true
                }
                if itemApplied || metadataApplied {
                    emit(.itemUpdated(id: payload.item.id))
                }
            }

        case "catchup_too_old":
            // Server signaled the requested Last-Event-ID is older than the
            // retention window. The stream is closed after this event; clear
            // our cursor and run a fresh full resync so the next reconnect
            // opens a stream with no cursor.
            //
            logger.log.info("sync.catchup_too_old — running a full resync")
            // The same catch-up the engine runs when it comes online, forced
            // past the never-imported test because this store has imported
            // before and still needs another one. It drains before importing
            // for the same reason it always does, and two of these events
            // landing on actor reentry share one import through the slot the
            // catch-up publishes rather than racing over the store.
            //
            // **The cursor is cleared after the import, not before it, and the
            // order is the whole point.** Clearing first meant the next stream
            // opened fresh whether or not the import had run — so a catch-up
            // that declined, because the queue had not drained, left the
            // cursor gone and the gap unrepairable: the reconnect asks for
            // everything since now, and the later catch-up returns at the
            // `hasImported` test without ever filling the hole. Keeping the
            // cursor means the server refuses it again on the next reconnect,
            // which looks like a loop and is the retry — it repairs itself the
            // moment the queue drains. A suspended space is exactly the case
            // that keeps a queue undrained for longer than a retention window.
            let outcome = await catchUp(forceImport: true)
            switch outcome {
            case .imported:
                try? await mutationQueue.clearSyncState(key: cursorKey)
            case .skipped:
                logger.log.error(
                    "sync.catchup_too_old.resync_skipped reason=queue_not_drained — cursor kept so a later reconnect can repair the gap"
                )
            case .failed(let error):
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
            // The stream was closed by the server. The outer reconnect loop
            // reopens it — with no cursor when the import ran, and with the
            // old one when it did not, so the refusal repeats until it can.

        default:
            // A type this build has no case for. Reported rather than dropped
            // in silence: the engine cannot apply what it cannot recognize, and
            // an unrecognized type used to look exactly like one deliberately
            // ignored. That is what let `item.purged` sit unhandled — the
            // server announced a removal, the client kept the row, and no
            // signal anywhere distinguished the two.
            // Once per distinct type, not once per frame. The set is bounded by
            // what a server can name, but the *frames* are not: a server
            // emitting an unknown high-rate type would otherwise write an error
            // line per event, and a log that floods is one nobody reads — which
            // is the failure this arm was added to end, arrived at from the
            // other side. `insert` reports whether it was new, so the check
            // costs nothing beyond the bookkeeping already here.
            if unhandledEventTypes.insert(eventType).inserted {
                logger.log.error(
                    "sync.sse.unhandled_event event=\(eventType, privacy: .public)"
                )
            }
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

        let cycle: (replayable: [PendingMutationRecord], blockedSince: [String: String])
        do {
            cycle = try await replayableRecords()
        } catch {
            recordSyncFailure(error)
            return
        }
        // A queue holding nothing but blocked rows is not a cycle. Entering one
        // would emit `.syncing`, walk the rows, skip every one and emit again
        // next time — a device flapping through a syncing state forever over a
        // write the engine has already stopped asking about.
        guard !cycle.replayable.isEmpty else {
            await recordCleanDrainIfQueueIsEmpty()
            return
        }

        await connectionManager.markSyncing()
        emit(.syncing)
        let decoder = JSONDecoder()

        // Track only transient errors for the cycle-level `.failed` emit.
        // Permanent errors (400/403/404, but not a `space_suspended` 403 —
        // that is the environment rather than the write) drop the offending
        // record and emit
        // `.mutationDropped` — they don't mean "sync failed," they mean
        // "this mutation will never succeed, don't keep trying."
        var transientError: Error?
        var remaining = cycle.replayable

        // Item ids this cycle must not run ahead of. Two things put an id here
        // and both are the queue's per-item ordering being kept.
        //
        // A `createItem` that failed transiently: `deleteItem(A)` fired
        // straight after would 404, because the item never landed, and a 404 is
        // permanent — so the delete would be dropped, and the next cycle's
        // successful `createItem(A)` would leave the server holding an item the
        // client has already deleted.
        //
        // A blocked row: replaying a later edit to the same item over an
        // earlier one that has not landed applies the two out of order, and
        // whatever the blocked edit was carrying is silently lost. Unrelated
        // items are untouched either way — holding the whole queue behind one
        // blocked row would reproduce the defect this state exists to fix.
        var blockedSince = cycle.blockedSince

        // Items stopped during *this* cycle. Membership alone defers, with no
        // timestamp comparison: the loop walks the queue in order, so anything
        // still to come is by definition queued after the row that stopped.
        // `blockedSince` answers the other half — rows blocked in an earlier
        // cycle, where the queue holds writes on both sides of the block.
        var stoppedThisCycle = Set<String>()



        // Records this cycle chose not to attempt. The clean-drain decision
        // reads it: a row deferred behind a blocked one is not outstanding work
        // the cycle failed to do, and counting it as such is what withheld
        // `.synced` forever from the very shape this feature creates.
        var deferredRecordIds = Set<String>()

        while !remaining.isEmpty {
            let record = remaining.removeFirst()
            guard running else { return }

            // Hold back an item-scoped mutation queued after the row that
            // stopped for this item — a `createItem` still awaiting a transient
            // retry, or a blocked row. Replaying it now would either 404 (the
            // item never landed, and a 404 is permanent, so the row would be
            // dropped before the create got another chance) or apply two edits
            // out of order and lose what the stopped one carried. A row queued
            // *before* the one that stopped is not out of order with it and
            // keeps being attempted.
            if let localId = record.localId,
               record.kind != .createItem,
               stoppedThisCycle.contains(localId)
                   || blockedSince[localId].map({ record.createdAt >= $0 }) == true {
                deferredRecordIds.insert(record.id)
                let cause = stoppedThisCycle.contains(localId) ? "stopped_this_cycle" : "blocked"
                logger.log.info(
                    "sync.mutation.deferred kind=\(record.kind.rawValue, privacy: .public) item_id=\(localId, privacy: .public) reason=\(cause, privacy: .public)"
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
                        // Re-partition rather than re-fetch: a plain fetch
                        // returns blocked rows too, and putting one back into
                        // `remaining` would replay the very row the drain has
                        // undertaken to skip. Take the recomputed cut-off with
                        // it — dropping it would leave the rest of the cycle
                        // deferring on in-cycle membership alone, so a row
                        // blocked in an earlier cycle would stop holding back
                        // the writes queued after it.
                        let repartitioned = try await replayableRecords()
                        remaining = repartitioned.replayable
                        blockedSince = repartitioned.blockedSince
                    } catch {
                        recordSyncFailure(error)
                        return
                    }
                }
            } catch let marfaError as MarfaError
                where Self.isFinal(marfaError, kind: record.kind) {
                // Persist the dropped row + remove the live row in one
                // SQLite transaction. The dropped log is the
                // ``DroppedMutationsQuery`` source of truth; cascade
                // orphans land in the same log via
                // ``MutationQueue/dropMutationsReferencingLocalId(_:droppedAt:error:)``.
                let droppedAt = Date()
                // An atomic bulk page arrives as a 400 describing the
                // rollback, with the refusal that caused it one level down.
                // The log and the event carry the refusal, because
                // `bulk_atomic_rollback` tells an app that something was
                // refused and never which thing.
                let reported = Self.reportedRefusal(marfaError)
                try? await mutationQueue.recordDropped(
                    record: record,
                    droppedAt: droppedAt,
                    error: reported
                )
                logger.log.error(
                    "sync.mutation.dropped kind=\(record.kind.rawValue, privacy: .public) item_id=\(record.localId ?? "-", privacy: .public) attempt=\(record.attemptCount + 1, privacy: .public) status=\(reported.status, privacy: .public) code=\(reported.code, privacy: .public)"
                )
                emit(.mutationDropped(
                    kind: record.kind.rawValue,
                    itemId: record.localId,
                    attempt: record.attemptCount + 1,
                    error: reported
                ))

                // A refused edge create leaves a local row nothing can ever
                // reconcile, so it goes with the mutation. Every permanent
                // refusal rather than only a conflict: what refused the
                // create does not change the fact that the row can never
                // reach the server.
                if record.kind == .createEdge, let localId = record.localId {
                    try? await localStore.deleteEdge(id: localId)
                }

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
                        // An orphaned edge create has a local row too, and it
                        // now points at an item that has just been purged.
                        // The direct path above never sees these: they are
                        // dropped by the cascade rather than by a refusal of
                        // their own.
                        if ghost.kind == .createEdge, let ghostId = ghost.localId {
                            try? await localStore.deleteEdge(id: ghostId)
                        }
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
                        // Re-partition rather than re-fetch: a plain fetch
                        // returns blocked rows too, and putting one back into
                        // `remaining` would replay the very row the drain has
                        // undertaken to skip. Take the recomputed cut-off with
                        // it — dropping it would leave the rest of the cycle
                        // deferring on in-cycle membership alone, so a row
                        // blocked in an earlier cycle would stop holding back
                        // the writes queued after it.
                        let repartitioned = try await replayableRecords()
                        remaining = repartitioned.replayable
                        blockedSince = repartitioned.blockedSince
                    } catch {
                        recordSyncFailure(error)
                        return
                    }
                }
            } catch {
                // One question, asked once: can the next drain do any better?
                if let reason = PendingMutationBlockReason.classify(
                    error: error,
                    kind: record.kind,
                    refusalCount: record.refusalCount,
                    ceiling: maxReplayAttempts
                ) {
                    try? await mutationQueue.recordBlocked(
                        id: record.id, reason: reason, error: formatLastError(error)
                    )
                    logger.log.error(
                        "sync.mutation.blocked kind=\(record.kind.rawValue, privacy: .public) item_id=\(record.localId ?? "-", privacy: .public) attempt=\(record.attemptCount + 1, privacy: .public) reason=\(reason.rawValue, privacy: .public)"
                    )
                    emit(.mutationBlocked(
                        kind: record.kind.rawValue, itemId: record.localId, reason: reason
                    ))

                    // **One refusal that is not about this write.** The
                    // credential every queued row carries has been refused, so
                    // sending the rest to be refused one at a time spends a
                    // request per write to learn what this one already said —
                    // and leaves an app showing a count that drops to zero
                    // through failure. Rows already blocked keep the reason
                    // they have: a conflict awaiting review is not resolved by
                    // a new credential.
                    if reason == .credentialRefused {
                        let parked = (try? await mutationQueue.parkAllLive(
                            reason: .credentialRefused,
                            error: formatLastError(error)
                        )) ?? 0
                        // **And the pass ends here.** Parking the rows in the
                        // store is not enough on its own: this loop is walking
                        // a list it fetched before any of them changed, so
                        // without this it goes on to send every one of them and
                        // be refused identically — spending a request per write
                        // to learn what this one already said, and reclassifying
                        // each on the way.
                        //
                        // The announcement is left to the tail, which reads the
                        // queue and so needs no arithmetic, and which is where
                        // it has to be anyway: a park announced here and a
                        // failure recorded there would reach a latched consumer
                        // in that order.
                        remaining.removeAll()
                        logger.log.error(
                            "sync.queue.parked reason=\(reason.rawValue, privacy: .public) count=\(parked + 1, privacy: .public)"
                        )
                    }

                    // Deliberately does not set `transientError`. The engine
                    // has stopped asking about this row, so it is not something
                    // the cycle failed to do — and one such row used to make
                    // every later cycle report failure, which is the half of
                    // this defect an app actually saw.
                    if let localId = record.localId {
                        stoppedThisCycle.insert(localId)
                    }
                } else {
                    transientError = error
                    // A failure the environment caused was never an answer,
                    // so it raises the displayed attempt count and not the
                    // refusal count the ceiling reads.
                    //
                    // **And neither is a failure the server never saw.** A
                    // store write in the replay runs *after* a 2xx —
                    // adopting the row the server returned — so a store that
                    // refuses there is a write the server accepted. Counting
                    // it as a refusal spends the budget on an answer that was
                    // yes, and a store failing for its own environmental
                    // reason, a locked device or a full disk, spends all of
                    // it. Only a refusal the server actually sent counts.
                    try? await mutationQueue.recordFailure(
                        id: record.id, error: formatLastError(error),
                        wasRefusedByTheServer:
                            PendingMutationBlockReason.isServerRefusal(error)
                    )
                    logger.log.info(
                        "sync.mutation.failed kind=\(record.kind.rawValue, privacy: .public) item_id=\(record.localId ?? "-", privacy: .public) attempt=\(record.attemptCount + 1, privacy: .public) reason=\(String(describing: type(of: error)), privacy: .public)"
                    )
                    if record.kind == .createItem, let localId = record.localId {
                        stoppedThisCycle.insert(localId)
                    }
                }
            }
        }

        // **A parked queue is the cycle's outcome, whatever else happened in
        // it.** Two things made this necessary rather than tidy. A row that
        // failed transiently *before* another was refused leaves
        // `transientError` set, so the cycle emitted `.queueParked` and then
        // `.failed` — and a consumer folding events into a latched state, which
        // is what `FullSyncStateQuery` is, keeps the last one. And a park laid
        // down in an *earlier* cycle is overwritten by any later cycle that
        // fails, because nothing re-emits the park: `queueParked` is not
        // latched, by design, since it answers "this just happened".
        //
        // So the engine says it rather than leaving a reader to re-derive it.
        // `.failed` is withheld rather than the park being re-emitted after it,
        // because a cycle that parked did not fail — it stopped, and the two
        // want different words from an app.
        let parkedNow = (try? await mutationQueue.counts.blocked[.credentialRefused]) ?? nil
        if let parkedNow, parkedNow > 0 {
            emit(.queueParked(reason: .credentialRefused, count: parkedNow))
            return
        }

        if let transientError {
            recordSyncFailure(transientError)
        } else {
            await recordCleanDrainIfQueueIsEmpty(skipped: deferredRecordIds)
        }
    }

    /// Whether a replay failure is a create meeting a 409, which no retry
    /// can clear.
    ///
    /// A synced client names a row before the server has seen it and sends
    /// that id with the create, so a lost response is retried under the same
    /// id. The server answers a repeat of an id this caller already holds
    /// with the row itself rather than a refusal. What is left when a 409
    /// does arrive is an id belonging to a space this caller cannot see, or a
    /// row whose type is not the one declared — and the identical request
    /// will be answered identically for as long as it is sent. Retrying it
    /// strands the item, and the queue's ordering strands every later edit to
    /// it behind the retry.
    ///
    /// Decided here rather than in ``MarfaError/isPermanent`` because the
    /// status alone cannot decide it: the same 409 on an *update* is the
    /// ordinary version conflict, which resolves through the conflict
    /// strategy and must keep doing so. What makes it permanent is the pair —
    /// this status, on a create.
    private static func isUnresolvableCreateConflict(
        _ error: MarfaError,
        kind: MutationKind
    ) -> Bool {
        guard error.status == 409 else { return false }
        switch kind {
        case .createItem, .createEdge: return true
        default: return false
        }
    }

    /// Dead-letters the items a bulk action could not apply.
    ///
    /// The third door, and the one whose result is least obviously per-entry:
    /// the call is driven by a filter rather than a list, so there is no page
    /// to index into. It still fails per item, and `BulkActionResult.errors`
    /// names each one with the id it failed on and the code it failed with.
    /// Discarding that made a job that matched a thousand items and applied
    /// none of them indistinguishable from one that applied them all.
    ///
    /// Keyed by item id rather than position for the same reason: the id is
    /// what the server reports and the only thing that identifies the entry.
    private func applyBulkActionResult(
        _ result: BulkActionResult,
        record: PendingMutationRecord
    ) async {
        guard let errors = result.errors, !errors.isEmpty else { return }

        let refused = errors.map { entry in
            MutationQueue.DroppedBulkEntry(
                key: entry.id,
                localId: entry.id,
                // The action is what was attempted; there is no per-item
                // input to keep, because the caller supplied a filter.
                payloadJson: (try? Self.entryEncoder.encode(["id": entry.id, "action": result.action]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}",
                error: MarfaError(
                    code: entry.code,
                    message: entry.message,
                    status: 0,
                    details: ["id": .string(entry.id)]
                )
            )
        }

        try? await mutationQueue.recordDroppedBulkEntries(
            record: record, entries: refused, droppedAt: Date()
        )
        for entry in refused {
            logger.log.error(
                "sync.bulk_action.entry_dropped item_id=\(entry.key, privacy: .public) code=\(entry.error.code, privacy: .public)"
            )
            emit(.mutationDropped(
                kind: record.kind.rawValue,
                itemId: entry.localId,
                attempt: record.attemptCount + 1,
                error: entry.error
            ))
        }
    }

    /// One entry's answer, flattened out of whichever bulk result carried
    /// it. The item and edge doors answer in two types with identical
    /// fields, and everything below treats them the same way, so reading
    /// them twice would only be two chances to diverge.
    private struct BulkEntryOutcome {
        let index: Int
        let outcome: BulkOutcome
        let id: String?
        let error: BulkResultError?
    }

    /// Encoder for the single entry a dropped row keeps. Separate from the
    /// transport's so a change to wire encoding cannot quietly reshape what
    /// is already written into the dead-letter log.
    private static let entryEncoder = JSONEncoder()

    /// Reads what the server did with each entry of a bulk page.
    ///
    /// Two things the replay used to discard entirely. **An entry the server
    /// refused** was thrown away with the rest of the response, so a page
    /// where every entry errored left the queue as a clean success: no
    /// dead-letter row, no event, nothing an app could show, and the writes
    /// simply gone. Each refusal now lands in the dropped-mutation log under
    /// its own id and emits ``SyncEvent/mutationDropped``, exactly as a
    /// single-record mutation does.
    ///
    /// **An id the server named differently** is logged rather than
    /// repaired. Both bulk doors are sent the id each local row was written
    /// under and answer with the id they stored, so the two agreeing is the
    /// contract; a create that disagrees means it broke. An upsert resolving
    /// an existing row by `(source, source_id)` disagrees legitimately, and
    /// the device then holds a row the server does not — but the answer
    /// carries an id and not a row, so there is nothing here to adopt, and
    /// fetching one per entry would turn a page into a page of round trips.
    /// The catch-up import is what reconciles it; the log line is what makes
    /// it visible in the meantime.
    private func applyBulkResult(
        entries: [BulkEntryOutcome],
        queuedIds: [String?],
        queuedPayloads: [String?],
        record: PendingMutationRecord
    ) async {
        var refused: [MutationQueue.DroppedBulkEntry] = []

        for entry in entries {
            // The server indexes its answer against the page it was sent, so
            // an index outside it means the two disagree about what was sent.
            // Nothing here can act on that, and guessing an entry would
            // attribute a refusal to the wrong row.
            guard queuedIds.indices.contains(entry.index) else {
                logger.log.error(
                    "sync.bulk.entry_index_out_of_range kind=\(record.kind.rawValue, privacy: .public) index=\(entry.index, privacy: .public) sent=\(queuedIds.count, privacy: .public)"
                )
                continue
            }
            let queuedId = queuedIds[entry.index]

            switch entry.outcome {
            case .created, .updated:
                if let queuedId, let served = entry.id, served != queuedId {
                    logger.log.error(
                        "sync.bulk.id_not_kept kind=\(record.kind.rawValue, privacy: .public) index=\(entry.index, privacy: .public) outcome=\(entry.outcome.rawValue, privacy: .public) sent=\(queuedId, privacy: .public) returned=\(served, privacy: .public)"
                    )
                }

            case .skipped:
                // A `create_only` page meeting a row that already exists.
                // Nothing was written and nothing was lost — the row this
                // entry describes is on the server either way.
                logger.log.info(
                    "sync.bulk.entry_skipped kind=\(record.kind.rawValue, privacy: .public) index=\(entry.index, privacy: .public) local_id=\(queuedId ?? "-", privacy: .public)"
                )

            case .errored:
                // Status 0 rather than a fabricated HTTP code: the call
                // itself answered 200 and this entry's refusal never had a
                // status of its own. `DroppedMutationModel.errorStatus`
                // reserves 0 for exactly that.
                let error = MarfaError(
                    code: entry.error?.code ?? "bulk_entry_errored",
                    message: entry.error?.message
                        ?? "The server refused entry \(entry.index) of this bulk page.",
                    status: 0,
                    details: ["index": .int(entry.index)]
                )
                refused.append(
                    MutationQueue.DroppedBulkEntry(
                        key: String(entry.index),
                        localId: queuedId,
                        payloadJson: queuedPayloads[entry.index] ?? "{}",
                        error: error
                    )
                )
            }
        }

        guard !refused.isEmpty else { return }

        try? await mutationQueue.recordDroppedBulkEntries(
            record: record,
            entries: refused,
            droppedAt: Date()
        )
        for entry in refused {
            logger.log.error(
                "sync.bulk.entry_dropped kind=\(record.kind.rawValue, privacy: .public) key=\(entry.key, privacy: .public) local_id=\(entry.localId ?? "-", privacy: .public) code=\(entry.error.code, privacy: .public)"
            )
            emit(.mutationDropped(
                kind: record.kind.rawValue,
                itemId: entry.localId,
                attempt: record.attemptCount + 1,
                error: entry.error
            ))
        }
    }

    /// The per-entry refusal inside an atomic rollback, when that is what
    /// this error is.
    ///
    /// `POST /items/bulk` defaults to `atomic: true`, so one refused entry
    /// rolls the page back and answers `400 bulk_atomic_rollback` carrying
    /// `{ index, code, message }`. The 400 describes the rollback; the code
    /// underneath describes what was actually wrong, and it is the only part
    /// worth reporting to an app.
    private static func atomicRollbackCode(_ error: MarfaError) -> String? {
        guard error.code == "bulk_atomic_rollback" else { return nil }
        return error.details?["code"]?.stringValue
    }

    /// The error worth reporting for a failure, which for an atomic rollback
    /// is the refusal it carries rather than the wrapper that delivered it.
    private static func reportedRefusal(_ error: MarfaError) -> MarfaError {
        guard let code = atomicRollbackCode(error) else { return error }
        return MarfaError(
            code: code,
            message: error.details?["message"]?.stringValue ?? error.message,
            status: error.status,
            details: error.details
        )
    }

    /// Whether a replay failure is one no retry can clear.
    ///
    /// One place, because a status alone cannot answer it: a `409` is the
    /// ordinary version conflict on an update and final on a create.
    ///
    /// **An atomic rollback needs no clause here, and that is a fact about
    /// the server rather than an omission.** A rolled-back page arrives as a
    /// `400`, which is already final, and every reason the route can roll a
    /// page back on is a validation-class refusal of one entry's content —
    /// an unknown type, a timestamp that does not parse, a type the
    /// credential may not write. The codes one might expect to be worth
    /// retrying cannot reach it: quota is reserved by a path this route does
    /// not call, rate limits and a suspended space are refused by middleware
    /// before the route runs, and a version conflict needs a version the
    /// bulk update never sends. So a rollback is dead-lettered, and what
    /// makes that safe is that the page wrote nothing.
    ///
    /// **Composes with the blocked-state classifier rather than competing
    /// with it.** This answers "can a retry ever clear this", and only a
    /// failure it calls final is dead-lettered. A failure it does not is
    /// still queued, and what happens to it then — retried, or held in a
    /// blocked state a person has to resolve — is the classifier's question,
    /// asked after this one. A rollback never reaches it.
    private static func isFinal(_ error: MarfaError, kind: MutationKind) -> Bool {
        if error.isPermanent { return true }
        return isUnresolvableCreateConflict(error, kind: kind)
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
    private func recordCleanDrainIfQueueIsEmpty(skipped: Set<String> = []) async {
        guard running else { return }
        guard await lastFullSyncAt != nil else { return }
        // What counts as outstanding is what this cycle could have attempted and
        // did not finish — not simply what is left in the queue. Blocked rows
        // are excluded because the drain will not attempt them, and so are rows
        // this cycle deferred behind one, because those are held back by the
        // block rather than by a failure.
        //
        // Asking the queue for a count instead is the bug this replaces: a SQL
        // count cannot see the per-cycle deferral, so a blocked row on an item
        // with any later write to that item left one row outstanding forever.
        // That withheld `.synced` permanently and, on the retries-exhausted
        // path, left the `.failed` from the attempt before the block standing in
        // `fullSyncState` for good, since a clean drain is the only thing that
        // clears it.
        //
        // **One reason is excepted, because it does not stop a row — it stops
        // the queue.** Every other block is one write waiting on one decision,
        // and the rest of the queue really did drain. A refused credential
        // parks all of them, so "nothing outstanding" becomes true for the
        // worst reason there is, and a status line built on this says "synced
        // just now" over work that cannot move until a person signs in again.
        //
        // Read from the store rather than remembered from the pass that
        // parked. That was the first shape of this fix and it covered one
        // pass: a fully parked queue has no replayable rows, so the *next*
        // drain takes an early return that never reaches here, and the
        // engine's own catch-up and stream-close paths produce one within
        // milliseconds. Per-pass state cannot answer a question about the
        // queue's condition.
        let rows: [PendingMutationRecord]
        do {
            rows = try await mutationQueue.fetchAll()
        } catch {
            recordSyncFailure(error)
            return
        }
        if rows.contains(where: { $0.blockedReason == .credentialRefused }) { return }
        let outstanding = rows.filter {
            $0.state != .blocked && !skipped.contains($0.id)
        }
        guard running, outstanding.isEmpty else { return }
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

    /// Splits the queue into the rows this cycle will attempt and the item ids
    /// it must not run ahead of.
    ///
    /// A blocked row is skipped rather than replayed, with one exception that
    /// is the whole of its recovery story: a row blocked only because no
    /// conflict resolver was registered becomes replayable the moment one is,
    /// with no call from the app and nothing to notify. Asking the registry
    /// here is what makes that true, and it is asked once per cycle rather than
    /// per row.
    private func replayableRecords() async throws
        -> (replayable: [PendingMutationRecord], blockedSince: [String: String]) {
        let all = try await mutationQueue.fetchAll()
        let hasResolver = await conflictResolvers?.current() != nil

        var replayable: [PendingMutationRecord] = []
        var blockedSince: [String: String] = [:]
        for record in all {
            guard record.state == .blocked else {
                replayable.append(record)
                continue
            }
            if record.blockedReason == .resolverMissing, hasResolver {
                replayable.append(record)
                continue
            }
            // Keyed by the earliest blocked row for the item, so only writes
            // queued after it wait. A row queued *before* a blocked one is not
            // out of order with it and must keep being attempted — otherwise a
            // write taking 503s beside a later blocked sibling would be skipped
            // forever while still projecting `.retrying` on a frozen count.
            //
            // `createdAt` has millisecond resolution, so two writes made inside
            // one millisecond tie. The comparison is `>=`, which makes a tie
            // wait: ordering is worth more here than liveness, because letting
            // a same-millisecond sibling replay over an earlier blocked edit is
            // exactly the out-of-order loss this deferral exists to prevent.
            // What the tie costs is that such a sibling waits for the block to
            // clear even though nothing can prove it was queued later.
            if let localId = record.localId {
                blockedSince[localId] = min(
                    blockedSince[localId] ?? record.createdAt, record.createdAt
                )
            }
        }
        return (replayable, blockedSince)
    }

    /// Returns `true` if the replay rewrote a local-id in the queue, signaling
    /// to the caller that the in-memory replay list is stale.
    @discardableResult
    private func replayRecord(_ record: PendingMutationRecord, decoder: JSONDecoder) async throws -> Bool {
        let data = record.payloadJson.data(using: .utf8) ?? Data()

        // Every write below goes out under this row's key, and it is applied
        // by SHADOWING the engine's transport rather than by passing it to
        // sixteen call sites. That is deliberate: the switch has one arm per
        // mutation kind, and a seventeenth kind added later would compile,
        // ship, and silently send no key — a defect invisible until a lost
        // response duplicated somebody's data. A wrapper cannot be forgotten
        // by a case that has not been written yet.
        let transport = KeyedTransport(base: self.transport, key: record.idempotencyKey)

        switch record.kind {

        case .createItem:
            let p = try decoder.decode(CreateItemPayload.self, from: data)
            let response: ItemResponse = try await transport.request(
                method: .post, path: "/items", body: p.input, query: nil
            )
            // Adopt the row the server answered with, as the edge path does.
            // It carries what the local mint could not know — the space, the
            // version, the server's timestamps — and on a repeat it is not
            // the echo of this request at all: the server recognizes an id it
            // already holds, writes nothing, and hands back the row as it
            // stands. That is the state this device should be showing.
            //
            // The metadata row travels with it and is adopted the same way.
            // The item first: a metadata row attaches to its item as it is
            // written, so storing the sidecar for an item the store does not
            // hold would orphan it.
            //
            // A write queued behind this create replays after it, so the
            // adopted row can be momentarily older than the local one until
            // that write lands and the server echoes it — the same exposure
            // an inbound `item.updated` frame already carries, converging the
            // same way.
            //
            // Thrown rather than swallowed, as the edge path throws: a store
            // that refuses the write has not adopted anything, and treating
            // that as success would remove the mutation from the queue and
            // leave the device holding the row it minted with nothing left to
            // correct it. Throwing keeps the record queued for the next drain.
            try await localStore.upsertItem(response.item)
            if let metadata = response.metadata {
                try await localStore.upsertMetadata(metadata)
            }
            // Reconcile local-id → server-id in the local store and in any
            // dependent queued mutations. Under the current flow this branch
            // never fires — `ItemsNamespace.create` stamps the local UUIDv7
            // into `input.id` so the server echoes it back. Preserved as
            // defense against a future server-assigned-id path or direct
            // callers that bypass the namespace.
            if let localId = record.localId, localId != response.item.id {
                try await mutationQueue.rewriteLocalId(from: localId, to: response.item.id)
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
                    // **`self.transport`, NOT the keyed shadow, and the key is
                    // passed as an argument instead.** The shadow would stamp
                    // the row's key on every attempt, and only the first one
                    // can carry it: a resolver-driven retry re-reads the
                    // server's copy and re-sends a different body, which a
                    // keyed repeat is answered with a `422`. The loop is the
                    // only code that knows which attempt it is on, so it is
                    // the only code that can make that call.
                    transport: self.transport,
                    itemId: p.id,
                    clientPatch: p.properties,
                    version: v,
                    strategy: strategy,
                    resolver: resolver,
                    tier: p.tier,
                    sourceId: p.sourceId,
                    idempotencyKey: record.idempotencyKey
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
            // The id the local store minted when the app made this edge. It
            // lives in the record's own column rather than the payload —
            // `enqueueCreateEdge` puts it there and the cascade logic already
            // reads it as the edge's id. Sending it is what keeps the
            // server's row under the id this device has already written, so
            // the `edge.created` echo that follows updates that row instead
            // of inserting a second one beside it.
            let body = CreateEdgeBody(
                id: record.localId,
                sourceId: p.source, targetId: p.target,
                edgeType: p.edgeType, properties: p.properties
            )
            let response: EdgeResponse = try await transport.request(
                method: .post, path: "/edges", body: body, query: nil
            )
            // The route keeps the id it is given, so a different one coming
            // back means that contract broke. Nothing here can repair it —
            // the local row is already under the old id and the app may hold
            // that id — but a duplicate row appearing with no trace of why is
            // what made this defect expensive to find, so say so.
            if let localId = record.localId, response.edge.id != localId {
                logger.log.error(
                    "sync.edge.id_not_kept sent=\(localId, privacy: .public) returned=\(response.edge.id, privacy: .public)"
                )
            }
            // Adopt the server's copy, which carries the space and the
            // timestamps the local mint could not know. A repeat the server
            // acknowledges answers with the row it already holds and lands
            // here the same way.
            try await localStore.upsertEdge(response.edge)

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

            // Upload succeeded. The response hash should match the
            // locally-computed one (same data, same SHA-256); if it does not,
            // the local hash was wrong and any items or edges created against
            // it will 404 on blob fetch. Log but do not fail — the blob IS on
            // the server.
            if let uploaded = try? JSONDecoder().decode(BlobUploadResponse.self, from: responseData),
               uploaded.hash != p.hash {
                logger.log.error(
                    "sync.uploadBlob.hash_mismatch local=\(p.hash, privacy: .public) server=\(uploaded.hash, privacy: .public)"
                )
            }
            // The bytes MOVE to the read cache rather than being dropped,
            // and this line is the defect the cache exists to close. The
            // outbound row was the only copy the device held, so deleting it
            // on success meant a person could save a picture, watch it sync,
            // and then not open it on a train — every read went back to the
            // network for a file the device had held minutes earlier.
            //
            // Cached before the row is removed, so a failure between the two
            // leaves the outbound copy rather than no copy.
            // **Cached under the address the SERVER acknowledged**, and only
            // when the two agree. The mismatch above is a diagnostic saying
            // every reference to the local hash will 404; caching under it
            // would make this one device the only place those bytes resolve,
            // silently masking the thing the log exists to raise.
            //
            // **The delete is guarded on the cache write succeeding.** A first
            // version ordered the two correctly and then swallowed a failure
            // with `try?`, so a cache write that threw still dropped the
            // outbound row and left neither copy — the ordering protects
            // against a crash between the lines and nothing else.
            let acknowledged = (try? JSONDecoder().decode(BlobUploadResponse.self, from: responseData))?.hash
            if acknowledged == nil || acknowledged == p.hash {
                do {
                    try await localStore.cacheBlob(
                        hash: p.hash, data: blobData, mimeType: p.mimeType
                    )
                    try? await mutationQueue.deletePendingBlob(hash: p.hash)
                } catch {
                    // The outbound row stays, so the bytes are still on this
                    // device and the next drain tries again. The blob is on
                    // the server either way, so nothing is lost by waiting.
                    logger.log.error(
                        "sync.uploadBlob.cache_failed hash=\(p.hash, privacy: .public) reason=\(String(describing: type(of: error)), privacy: .public)"
                    )
                }
            } else {
                try? await mutationQueue.deletePendingBlob(hash: p.hash)
            }
            emit(.blobUploadCompleted(hash: p.hash))

        case .bulk:
            let p = try decoder.decode(BulkPayload.self, from: data)
            let result: BulkResult = try await transport.request(
                method: .post, path: "/items/bulk", body: p.input, query: nil
            )
            await applyBulkResult(
                entries: result.results.map {
                    BulkEntryOutcome(index: $0.index, outcome: $0.outcome, id: $0.id, error: $0.error)
                },
                queuedIds: p.input.items.map(\.id),
                queuedPayloads: p.input.items.map { (try? Self.entryEncoder.encode($0)).flatMap { String(data: $0, encoding: .utf8) } },
                record: record
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
            let actionResult = try await BulkActionRunner.runToCompletion(
                transport: transport,
                input: p.input
            )
            await applyBulkActionResult(actionResult, record: record)

        case .bulkEdges:
            let p = try decoder.decode(BulkEdgesPayload.self, from: data)
            let result: BulkEdgeResult = try await transport.request(
                method: .post, path: "/edges/bulk", body: p.input, query: nil
            )
            await applyBulkResult(
                entries: result.results.map {
                    BulkEntryOutcome(index: $0.index, outcome: $0.outcome, id: $0.id, error: $0.error)
                },
                queuedIds: p.input.edges.map(\.id),
                queuedPayloads: p.input.edges.map { (try? Self.entryEncoder.encode($0)).flatMap { String(data: $0, encoding: .utf8) } },
                record: record
            )
        }

        return false
    }
}
