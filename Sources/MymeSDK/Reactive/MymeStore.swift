import Foundation
import Observation
import SwiftData

// MARK: - MymeStore

/// A `@MainActor` facade over ``LocalStore`` that vends live,
/// `@Observable` query objects for use in SwiftUI.
///
/// Obtain an instance from ``MymeClient/makeStore()`` (available when
/// the client was created with ``MymeClient/local(path:)`` or
/// ``MymeClient/synced(url:apiKey:storePath:)``):
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
/// Writes still go through the ``MymeClient`` namespace APIs
/// (``ItemsNamespace``, etc.), which keep the local store in sync and,
/// in synced mode, enqueue mutations for the server.
///
/// - Important: `MymeStore` must be created and used on the
///   `@MainActor`. It is safe to pass the store to
///   `@Observable @MainActor` SwiftUI views.
@Observable
@MainActor
public final class MymeStore {

    // MARK: - Internal

    private let container: ModelContainer

    /// The sync engine this store was vended against, if any. Populated
    /// for synced-mode clients; `nil` for pure-local. Gates
    /// ``queryBlobUploadProgress()`` — only synced clients have an
    /// engine whose `events` stream can drive blob progress.
    private let syncEngine: SyncEngine?

    // MARK: - Init

    init(container: ModelContainer, syncEngine: SyncEngine? = nil) {
        self.container = container
        self.syncEngine = syncEngine
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
    ///   - type: The ``MymeItem`` conforming type (e.g. `CoreNote.self`).
    ///   - filters: Additional filters (state, limit). The `type` filter
    ///     is derived automatically from `T.typeIdentifier`.
    public func typedQuery<T: MymeItem>(
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

    // MARK: - Tag queries

    /// Creates a live query over tag usage across the local store. See
    /// ``TagsQuery``.
    public func queryTags() -> TagsQuery {
        TagsQuery(container: container)
    }

    // MARK: - Sync queries

    /// Creates a live query over the pending-mutation queue.
    ///
    /// Surfaces every queued mutation with its projected
    /// ``PendingMutationStatus`` — `.pending`, `.inFlight`, or
    /// `.retrying(...)`. Apps use this to render richer offline UX
    /// than ``SyncEngine/hasPendingMutations`` allows: per-item badges,
    /// queue visualisations, retry banners.
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
}

// MARK: - Refetch observer (shared boilerplate)

/// Shared boilerplate for the seven reactive query types.
///
/// Subscribes to `ModelContext.didSave` notifications via the modern
/// `NotificationCenter.notifications(named:)` async sequence (no
/// observer-token leak risk — cancelling the consuming task tears
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
        // their own actor-bound contexts, not from `MymeStore`'s
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
        // Cancelling tasks is safe from a nonisolated deinit; the tasks
        // themselves are isolated to @MainActor and finish their work
        // there.
        listenerTask?.cancel()
        debounceTask?.cancel()
    }
}
