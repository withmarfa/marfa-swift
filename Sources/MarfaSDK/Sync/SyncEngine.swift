import Foundation

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
///    to connecting, the engine opens a `GET /events` SSE stream with the last
///    persisted `Last-Event-ID` cursor so it receives only events since the
///    previous session.
///
/// 2. **Applies SSE events** — each server-sent event is decoded and written
///    into the local store via ``LocalStore`` upsert helpers. Supported event
///    types: `item.created`, `item.updated`, `item.deleted`, `item.restored`,
///    `item.state_changed`, `edge.created`, `edge.deleted`,
///    `metadata.changed`.
///
/// 3. **Persists the Last-Event-ID cursor** — after every applied event the
///    cursor is saved in the `sync_state` table so reconnection resumes from
///    the correct position.
///
/// 4. **Replays the mutation queue** — once the catch-up SSE stream reaches
///    idle (no events received for a short interval, or the stream signals
///    normal completion), the engine drains ``MutationQueue`` by sending each
///    pending mutation to the server. On success the record is removed; on
///    failure the attempt count is incremented and the engine retries on the
///    next reconnection cycle.
///
/// 5. **Coordinates state** — the engine calls ``ConnectionStateManager``
///    `.markSyncing()` while replaying mutations and `.markOnline()` when the
///    queue is empty and the SSE stream is idle.
public actor SyncEngine {

    // MARK: - Dependencies

    private let transport: any Transport
    private let localStore: LocalStore
    private let mutationQueue: MutationQueue
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

    // Prevents overlapping `performInitialSync` runs when multiple
    // `catchup_too_old` events land during reconnection churn.
    private var resyncing = false

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
    public nonisolated var events: AsyncStream<SyncEvent> {
        AsyncStream<SyncEvent> { continuation in
            Task { await self.subscribe(continuation) }
            continuation.onTermination = { @Sendable _ in
                // Continuation finished — nothing to clean up explicitly;
                // the actor's stored continuations are pruned when their
                // `yield` returns `.terminated`.
            }
        }
    }

    private var continuations: [AsyncStream<SyncEvent>.Continuation] = []

    private func subscribe(_ continuation: AsyncStream<SyncEvent>.Continuation) {
        continuations.append(continuation)
    }

    private func emit(_ event: SyncEvent) {
        continuations.removeAll { c in
            switch c.yield(event) {
            case .terminated: return true
            default: return false
            }
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
        localStore: LocalStore,
        mutationQueue: MutationQueue,
        connectionManager: ConnectionStateManager,
        drainDebounceInterval: Duration = .milliseconds(150)
    ) {
        self.transport = transport
        self.localStore = localStore
        self.mutationQueue = mutationQueue
        self.connectionManager = connectionManager
        self.drainDebounceInterval = drainDebounceInterval
    }

    // MARK: - Lifecycle

    /// Starts the sync engine. Idempotent — calling again while already running
    /// is a no-op. Also starts the underlying ``ConnectionStateManager`` (which
    /// is itself idempotent) so `NWPathMonitor` begins delivering reachability
    /// updates; without this the engine's run loop would await on an inert
    /// stream stuck at `.offline`.
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
        await suspendStartPublicationIfNeededForTesting()
        guard starting, lifecycleGeneration == generation else { return }
        starting = false
        running = true
        streamTask = Task { [weak self] in
            await self?.runLoop()
        }
        drainListenerTask = Task { [weak self] in
            await self?.drainListenerLoop()
        }
    }

    /// Stops the sync engine and cancels the active SSE connection. Also stops
    /// the underlying ``ConnectionStateManager`` so `NWPathMonitor` releases
    /// its queue and any open `stateUpdates` streams finish.
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
        }
        stoppingTask = barrier
        await barrier.value
        stoppingTask = nil
    }

    /// Performs a one-shot catch-up import: paginates through `GET
    /// /items?include=metadata` and upserts each item plus its metadata into
    /// the local store. SSE alone only delivers events since the cursor, so
    /// without this call a freshly-signed-in app shows an empty store even
    /// when the server has history.
    ///
    /// Safe to call repeatedly — `upsertItem` / `setMetadata` are idempotent.
    /// Edges are not imported here; they arrive via SSE once emitted. V1
    /// apps that need thread/about edges for initial state should call
    /// ``ItemsNamespace/list(filters:)`` or add a per-item edge fetch.
    ///
    /// - Parameter pageSize: Server-side page size for each request.
    /// - Returns: The total number of items imported across all pages.
    /// - Throws: Transport errors from the pagination requests, or upsert
    ///   errors from the local store.
    @discardableResult
    public func performInitialSync(pageSize: Int = 200) async throws -> Int {
        var cursor: String? = nil
        var imported = 0
        repeat {
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
        for await state in await connectionManager.stateUpdates {
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

    // MARK: - Proactive drain on enqueue

    /// Listens to `mutationQueue.drainRequests` for the lifetime of the
    /// engine. Each ping schedules a debounced proactive drain — bursts
    /// of enqueues collapse into one replay cycle at the end.
    private func drainListenerLoop() async {
        let stream = await mutationQueue.drainRequests
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
        let state = await connectionManager.state
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
        let cursor = try? await mutationQueue.loadSyncState(key: cursorKey)

        var query: [(String, String)] = []
        if let cursor { query.append(("updated_after", cursor)) }

        let stream = transport.eventStream(
            path: "/events",
            query: query.isEmpty ? nil : query,
            lastEventID: cursor
        )

        var eventsConsumed = 0
        var errored = false
        do {
            for try await event in stream {
                guard running else { break }
                await applyEvent(event)
                eventsConsumed += 1
            }
        } catch {
            errored = true
        }

        await replayMutations()
        guard running else { return }
        await connectionManager.markOnline()

        // Reconnect nudge. Without this, a closed-but-not-errored SSE stream
        // (server-side idle timeout, catchup_too_old finalize, transport
        // timeout) would leave the engine parked on `.online` forever —
        // `runLoop` only re-enters `openStream` on a `.connecting` transition
        // from `NWPathMonitor`. After a brief back-off we flip
        // ConnectionStateManager back to `.connecting`, which runLoop picks
        // up and re-opens the stream. See Bug C in the v3.2.0 PR for the
        // "last synced 31 seconds ago" symptom this closes.
        //
        // A fast-fail (no events consumed AND an error thrown) stacks
        // exponential back-off to avoid hammering an unreachable server.
        // A healthy close (any event consumed, or clean finish) resets to
        // the base delay so SSE idle-reconnects stay snappy.
        //
        // Scheduled as a detached task — otherwise `openStream` wouldn't
        // return until the back-off elapsed, blocking `runLoop` from
        // observing state transitions (a real network drop, a manual
        // offline → connecting flip) that arrive during the wait.
        let fastFail = (eventsConsumed == 0 && errored)
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
        streamTask != nil || drainListenerTask != nil ||
            drainDebounceTask != nil || reconnectTask != nil
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
        await applyEvent(event)
    }

    private func applyEvent(_ event: SSEEvent) async {
        // Persist Last-Event-ID cursor before applying so we don't reprocess
        // on reconnect even if applying fails (events are idempotent upserts).
        if let id = event.id {
            try? await mutationQueue.saveSyncState(key: cursorKey, value: id)
        }

        guard let eventType = event.event else { return }
        let data = event.data.data(using: .utf8) ?? Data()
        let decoder = JSONDecoder()

        switch eventType {
        case "item.created":
            if let payload = decodeOrLog(ItemEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                try? await localStore.upsertItem(payload.item)
                emit(.itemCreated(id: payload.item.id))
            }

        case "item.updated", "item.restored", "item.state_changed":
            if let payload = decodeOrLog(ItemEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                try? await localStore.upsertItem(payload.item)
                emit(.itemUpdated(id: payload.item.id))
            }

        case "item.deleted":
            // Server sends the deleted item with state = trashed/purged.
            if let payload = decodeOrLog(ItemEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                try? await localStore.upsertItem(payload.item)
                emit(.itemDeleted(id: payload.item.id))
            }

        case "edge.created":
            if let payload = decodeOrLog(EdgeEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                try? await localStore.upsertEdge(payload.edge)
                emit(.edgeCreated(id: payload.edge.id))
            }

        case "edge.deleted":
            // Edge deletes carry just the edge ID in the data envelope.
            if let payload = decodeOrLog(EdgeEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                try? await localStore.deleteEdge(id: payload.edge.id)
                emit(.edgeDeleted(id: payload.edge.id))
            }

        case "metadata.changed":
            if let payload = decodeOrLog(MetadataEventPayload.self, from: data, eventType: eventType, decoder: decoder) {
                let input = MetadataInput(tags: payload.metadata.tags)
                _ = try? await localStore.setMetadata(itemId: payload.itemId, input: input)
                emit(.itemUpdated(id: payload.itemId))
            }

        case "catchup_too_old":
            // Server signaled the requested Last-Event-ID is older than the
            // retention window. The stream is closed after this event; clear
            // our cursor and run a fresh full resync so the next reconnect
            // opens a stream with no cursor.
            //
            // The `resyncing` guard is checked and set *before* the first
            // suspension point (`clearSyncState` hops to MutationQueue) so
            // that a concurrent `catchup_too_old` entering on actor reentry
            // observes the guard as already taken.
            guard !resyncing else {
                logger.log.info("sync.catchup_too_old — resync already in progress, skipping")
                break
            }
            resyncing = true
            logger.log.info("sync.catchup_too_old — clearing cursor and triggering full resync")
            try? await mutationQueue.clearSyncState(key: cursorKey)
            do {
                _ = try await performInitialSync()
            } catch {
                logger.log.error("sync.catchup_too_old.resync_failed reason=\(String(describing: type(of: error)), privacy: .public)")
            }
            resyncing = false
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
            recordReplayFailure(error)
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
                        recordReplayFailure(error)
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
                        recordReplayFailure(error)
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
            recordReplayFailure(transientError)
        } else {
            await recordCleanDrainIfQueueIsEmpty()
        }
    }

    private func recordReplayFailure(_ error: Error) {
        guard running else { return }
        lastFailedError = error
        lastFailedAt = Date()
        emit(.failed(error: error))
    }

    /// Re-reads the queue after a replay cycle before claiming success. A
    /// failed storage read, shutdown, or surviving row is an unknown or
    /// incomplete state, not a clean drain.
    private func recordCleanDrainIfQueueIsEmpty() async {
        guard running else { return }
        let queueIsEmpty: Bool
        do {
            queueIsEmpty = try await mutationQueue.isEmpty
        } catch {
            recordReplayFailure(error)
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
            recordReplayFailure(error)
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
            // returns. `.callback` degrades to `.auto` because the resolver
            // closure isn't serializable.
            if let v = p.version {
                let strategy: ConflictStrategy = {
                    switch p.conflict ?? .auto {
                    case .callback: return .auto
                    case let other: return other
                    }
                }()
                let result = try await handleConflictUpdateWithStats(
                    transport: transport,
                    itemId: p.id,
                    clientPatch: p.properties,
                    version: v,
                    strategy: strategy,
                    resolver: nil,
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
                    snapshot: nil,
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

            guard let blobData = try? await mutationQueue.fetchPendingBlob(hash: p.hash) else {
                // Blob data is gone — this can happen if the database was
                // partially corrupted or the row was manually deleted. The
                // upload can never succeed without the original bytes, so
                // treat it as a permanent validation failure and let the
                // engine drop it.
                let err = ValidationError(
                    message: "Pending blob data missing for hash \(p.hash); upload cannot be replayed"
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
