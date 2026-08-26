import Foundation
import Observation
import SwiftData

// MARK: - MarfaStore

/// A `@MainActor` facade over ``LocalStore`` that vends live,
/// `@Observable` query objects for use in SwiftUI.
///
/// Obtain an instance from ``MarfaClient/makeStore()`` (available when
/// the client was created with ``MarfaClient/local(path:)`` or
/// ``MarfaClient/synced(url:apiKey:storePath:)``):
///
///     guard let store = client.makeStore() else { return }
///     let notes = store.query(filters: ListFilters(type: "core.note"))
///     // `notes.items` updates whenever any `core.note` row changes.
///
/// Each query type opens its own `ModelContext` on `@MainActor`. A
/// single `NotificationCenter` subscription on
/// `ModelContext.didSave`, debounced by ``RefreshDebounce/interval``,
/// drives the refetch.
///
/// Writes still go through the ``MarfaClient`` namespace APIs
/// (``ItemsNamespace``, etc.), which keep the local store in sync and,
/// in synced mode, enqueue mutations for the server.
///
/// - Important: `MarfaStore` must be created and used on the
///   `@MainActor`. It is safe to pass the store to
///   `@Observable @MainActor` SwiftUI views.
@Observable
@MainActor
public final class MarfaStore {

    // MARK: - Internal

    private let container: ModelContainer

    /// The actor that owns the SwiftData reads. Only ``querySearch(text:filters:)``
    /// goes through it — the other queries hold their own `ModelContext`
    /// and fetch on the main actor, which is fine for a plain fetch but
    /// not for a scan that decodes JSON per row.
    private let localStore: LocalStore

    /// The sync engine this store was vended against, if any. Populated
    /// for synced-mode clients; `nil` for pure-local. Gates
    /// ``queryBlobUploadProgress()`` — only synced clients have an
    /// engine whose `events` stream can drive blob progress.
    private let syncEngine: SyncEngine?

    /// The mutation queue this store was vended against, if any.
    /// Used by ``queryDroppedMutations()`` and the dismissal
    /// forwarders (``dismissDropped(id:)``, ``dismissDroppedOlderThan(_:)``,
    /// ``dismissAllDropped()``). `nil` for clients without a local
    /// store; pure-local clients do have one (so `dismissDropped` can
    /// be called even if the engine never populated the log).
    private let mutationQueue: MutationQueue?

    /// The namespace that backs the ``profileStore`` accessor. Constructed
    /// lazily on first access; non-`nil` only for clients that have a
    /// remote profile endpoint to talk to.
    private let profileNamespace: ProfileNamespace?
    private var _profileStore: ProfileStore?

    // MARK: - Init

    init(
        container: ModelContainer,
        localStore: LocalStore,
        syncEngine: SyncEngine? = nil,
        mutationQueue: MutationQueue? = nil,
        profileNamespace: ProfileNamespace? = nil
    ) {
        self.container = container
        self.localStore = localStore
        self.syncEngine = syncEngine
        self.mutationQueue = mutationQueue
        self.profileNamespace = profileNamespace
    }

    // MARK: - Item queries

    /// Creates a live query over all items matching `filters`.
    ///
    /// The returned ``ItemQuery`` starts fetching immediately. Its
    /// `items` property is updated on the main actor whenever matching
    /// rows change.
    ///
    ///     let query = store.query()                          // all items
    ///     let notes = store.query(filters: .init(type: "core.note"))
    ///     let active = store.query(filters: .init(state: .active))
    public func query(filters: ListFilters? = nil) -> ItemQuery {
        ItemQuery(container: container, filters: filters)
    }

    /// Creates a live query over a single item by `id`.
    ///
    /// `query.item` is `nil` if the item doesn't exist or has been
    /// purged.
    public func queryItem(id: String) -> SingleItemQuery {
        SingleItemQuery(container: container, id: id)
    }

    /// Creates a live, typed query for items of a specific domain-model
    /// type.
    ///
    ///     let query = store.typedQuery(CoreNote.self)
    ///     // query.items is [CoreNote]
    ///
    /// - Parameters:
    ///   - type: The ``MarfaItem`` conforming type (e.g. `CoreNote.self`).
    ///   - filters: Additional filters (state, limit). The `type` filter
    ///     is derived automatically from `T.typeIdentifier`.
    public func typedQuery<T: MarfaItem>(
        _ type: T.Type,
        filters: ListFilters? = nil
    ) -> TypedItemQuery<T> {
        TypedItemQuery(container: container, filters: filters)
    }

    /// Creates a live query over items paired with their metadata. See
    /// ``ItemsWithMetadataQuery``.
    public func queryItemsWithMetadata(filters: ListFilters? = nil) -> ItemsWithMetadataQuery {
        ItemsWithMetadataQuery(container: container, filters: filters)
    }

    // MARK: - Edge queries

    /// Creates a live query over outbound edges from `sourceId`.
    ///
    /// - Parameters:
    ///   - sourceId: ID of the source item.
    ///   - edgeType: Restrict to this edge type, or `nil` for all.
    ///   - limit: Optional row cap.
    public func queryEdges(
        from sourceId: String,
        edgeType: String? = nil,
        limit: Int? = nil
    ) -> EdgesQuery {
        EdgesQuery(container: container, sourceId: sourceId, edgeType: edgeType, limit: limit)
    }

    /// Creates a live query over **all edges of a given type** across
    /// the entire local store.
    public func queryEdges(
        ofType edgeType: String,
        limit: Int? = nil
    ) -> EdgesQuery {
        EdgesQuery(container: container, edgeType: edgeType, limit: limit)
    }

    /// Creates a live query over **inbound edges for a batch of
    /// targets**. See ``BackrefsQuery``.
    public func queryBackrefs(
        to targetIds: [String],
        edgeType: String? = nil,
        limit: Int? = nil
    ) -> BackrefsQuery {
        BackrefsQuery(container: container, targetIds: targetIds, edgeType: edgeType, limit: limit)
    }

    // MARK: - Search

    /// Creates a live search over item `title` and `body`, served from
    /// the local store — no network, works offline.
    ///
    ///     let hits = store.querySearch(text: "invoice")
    ///     ForEach(hits.results, id: \.item.id) { hit in ... }
    ///
    /// `filters` takes the same surface as
    /// ``MarfaClient/search(query:filters:)`` (`type`, `state`, `tier`,
    /// `tags`, `limit`), so a screen can move between local and remote
    /// search without reshaping its query. The trade-offs that come with
    /// that — matched fields, ranking, no snippets — are documented on
    /// ``LocalStore/searchItems(text:filters:)``.
    ///
    /// The scan runs off the main actor. See ``SearchQuery``.
    public func querySearch(text: String, filters: SearchFilters? = nil) -> SearchQuery {
        SearchQuery(store: localStore, text: text, filters: filters)
    }

    // MARK: - Tag queries

    /// Creates a live query over tag usage across the local store. See
    /// ``TagsQuery``.
    public func queryTags() -> TagsQuery {
        TagsQuery(container: container)
    }

    /// Creates a live query over the distinct item types present in the local
    /// store. See ``TypesInDataQuery``.
    public func queryTypesInData() -> TypesInDataQuery {
        TypesInDataQuery(container: container)
    }

    // MARK: - Connection-aware queries

    /// Creates a live typed query over `system.connection` items.
    ///
    /// Filters by ``ConnectionKind`` (`app | integration`) and
    /// ``ItemState`` (`active | revoked`). Backed by ``TypedItemQuery``
    /// over the local store; observation rides the same
    /// `ModelContext.didSave` debounced refresh as every other reactive
    /// query.
    public func queryConnections(
        kind: ConnectionKind? = nil,
        state: ItemState? = nil,
        limit: Int? = nil
    ) -> TypedItemQuery<Connection> {
        var filters = ListFilters(state: state, limit: limit)
        if let kind {
            filters.filter = "kind=\"\(kind.rawValue)\""
        }
        return TypedItemQuery(container: container, filters: filters)
    }

    /// Creates a live typed query over `system.activity` items.
    ///
    /// Optional `severity` filter scopes the result (e.g.
    /// ``ActivitySeverity/actionRequired`` for a Repairs-style inbox).
    public func queryActivity(
        severity: ActivitySeverity? = nil,
        limit: Int? = nil
    ) -> TypedItemQuery<Activity> {
        var filters = ListFilters(limit: limit)
        if let severity {
            filters.filter = "severity=\"\(severity.rawValue)\""
        }
        return TypedItemQuery(container: container, filters: filters)
    }

    // MARK: - Profile

    /// `@Observable` view onto the calling user's profile.
    ///
    /// Returns `nil` for clients constructed without a server (pure-local
    /// mode) — `system.profile` is server-only. Subsequent calls return
    /// the same store instance so SwiftUI bindings remain stable across
    /// re-rendered parents.
    public var profileStore: ProfileStore? {
        if let existing = _profileStore { return existing }
        guard let namespace = profileNamespace else { return nil }
        let store = ProfileStore(namespace: namespace)
        _profileStore = store
        return store
    }

    // MARK: - Sync queries

    /// Creates a live query over the pending-mutation queue.
    ///
    /// Surfaces every queued mutation with its projected
    /// ``PendingMutationStatus`` — `.pending`, `.inFlight`, or
    /// `.retrying(...)`. Apps use this to render richer offline UX
    /// than ``SyncEngine/hasPendingMutations`` allows: per-item badges,
    /// queue visualizations, retry banners.
    ///
    /// Updates whenever any mutation is enqueued, transitions to
    /// `.inFlight`, records a transient failure, or is removed after
    /// successful replay. Shares the same `ModelContext.didSave`
    /// observation and 50 ms debounce as every other reactive query.
    public func queryPendingMutations() -> PendingMutationsQuery {
        PendingMutationsQuery(container: container)
    }

    /// Creates a live query over in-flight blob uploads.
    ///
    /// Returns `nil` when the store has no sync engine attached
    /// (pure-local clients) — there are no blob uploads to track
    /// without a server round-trip.
    ///
    /// The query subscribes to the engine's `events` stream and
    /// maintains a `uploads: [hash: BlobUploadProgress]` dict.
    /// Entries appear on ``SyncEvent/blobUploadStarted``, update on
    /// ``SyncEvent/blobUploadProgress``, and are evicted on
    /// ``SyncEvent/blobUploadCompleted``. Failures leave a `.failed`
    /// entry that's overwritten by a fresh start on transient retry.
    public func queryBlobUploadProgress() -> BlobUploadProgressQuery? {
        guard let syncEngine else { return nil }
        return BlobUploadProgressQuery(engine: syncEngine)
    }

    /// Creates a live query over the engine's ``FullSyncState``.
    ///
    /// Returns `nil` when the store has no sync engine attached
    /// (pure-local clients) — those shapes never produce drain
    /// cycles, so there's no meaningful state to render against.
    ///
    /// The query seeds its initial state from the persisted
    /// `last_clean_drain_at` timestamp, then folds
    /// ``SyncEngine/events`` (`.syncing` / `.synced(at:)` /
    /// `.failed(error:)`) into the discrete state machine. Apps use
    /// this to render confidence states — "waiting for first sync",
    /// "syncing", "synced N minutes ago", "couldn't sync" — without
    /// hand-rolling a reducer over the underlying signals.
    public func queryFullSyncState() -> FullSyncStateQuery? {
        guard let syncEngine else { return nil }
        return FullSyncStateQuery(engine: syncEngine)
    }

    /// Creates a live query over the dropped-mutation log.
    ///
    /// Returns `nil` when the store has no sync engine attached
    /// (pure-local clients) — those shapes never drop mutations,
    /// so the log would never grow.
    ///
    /// The query refreshes whenever any `ModelContext.save()` fires;
    /// `recordDropped`, the cascade insert path, and every dismissal
    /// API share the same notification observer the other reactive
    /// queries use.
    public func queryDroppedMutations() -> DroppedMutationsQuery? {
        guard syncEngine != nil else { return nil }
        return DroppedMutationsQuery(container: container)
    }

    // MARK: - Dropped mutation dismissal

    /// Removes a single dropped mutation row by id. No-op when the
    /// store has no mutation queue (network-only clients) or the
    /// row has already been dismissed.
    ///
    /// Forwards to ``MutationQueue/dismissDropped(id:)``. The reactive
    /// ``DroppedMutationsQuery`` picks up the change on the next
    /// `ModelContext.didSave` notification.
    public func dismissDropped(id: String) async throws {
        guard let mutationQueue else { return }
        try await mutationQueue.dismissDropped(id: id)
    }

    /// Removes every dropped mutation row whose `droppedAt` timestamp
    /// is **strictly** earlier than `cutoff`. Rows whose `droppedAt`
    /// exactly matches the cutoff are preserved.
    ///
    /// Useful for retention policies — e.g. "drop everything older
    /// than 30 days" — without committing the SDK to an opinionated
    /// default. No-op when the store has no mutation queue.
    public func dismissDroppedOlderThan(_ cutoff: Date) async throws {
        guard let mutationQueue else { return }
        try await mutationQueue.dismissDroppedOlderThan(cutoff)
    }

    /// Removes every dropped mutation row. No-op when the store has
    /// no mutation queue.
    public func dismissAllDropped() async throws {
        guard let mutationQueue else { return }
        try await mutationQueue.dismissAllDropped()
    }
}

// MARK: - Refetch observer (shared boilerplate)

/// Shared boilerplate for the seven reactive query types.
///
/// Subscribes to `ModelContext.didSave` notifications via the modern
/// `NotificationCenter.notifications(named:)` async sequence (no
/// observer-token leak risk — canceling the consuming task tears
/// down the subscription), coalesces bursts via
/// ``RefreshDebounce/interval``, and invokes the per-query refetch
/// closure on the `@MainActor`.
///
/// One instance per query. `cancel()` tears down both the listener
/// task and any pending debounce task; safe to call multiple times.
@MainActor
final class RefetchObserver {
    private var listenerTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    /// Starts the observer. The closure is retained for the lifetime of
    /// the observer; tear it down via `cancel()` (or by releasing the
    /// owning query) to avoid a strong-reference cycle.
    init(refetch: @escaping @MainActor () -> Void) {
        // `object: nil` — we want changes from any context against the
        // same container. `LocalStore` and `MutationQueue` write from
        // their own actor-bound contexts, not from `MarfaStore`'s
        // context.
        listenerTask = Task { @MainActor [weak self] in
            let stream = NotificationCenter.default.notifications(named: ModelContext.didSave)
            for await _ in stream {
                guard !Task.isCancelled, let self else { return }
                self.scheduleRefetch(refetch)
            }
        }
    }

    private func scheduleRefetch(_ refetch: @escaping @MainActor () -> Void) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(RefreshDebounce.interval))
            if Task.isCancelled { return }
            refetch()
        }
    }

    /// Cancels the listener task and any pending debounce task. Safe
    /// to call multiple times.
    func cancel() {
        listenerTask?.cancel()
        listenerTask = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    deinit {
        // Canceling tasks is safe from a nonisolated deinit; the tasks
        // themselves are isolated to @MainActor and finish their work
        // there.
        listenerTask?.cancel()
        debounceTask?.cancel()
    }
}
