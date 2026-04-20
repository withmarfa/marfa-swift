import Foundation
import GRDB
import Observation

// MARK: - MymeStore

/// A `@MainActor` facade over ``LocalStore`` that vends live, `@Observable`
/// query objects for use in SwiftUI.
///
/// Obtain an instance from ``MymeClient/store`` (available when the client was
/// created with ``MymeClient/local(path:)`` or ``MymeClient/synced(url:apiKey:storePath:)``):
///
///     guard let store = client.store else { return }
///     let notes = store.query(filters: ListFilters(type: "core.note"))
///     // `notes.items` updates whenever any `core.note` row changes.
///
/// All database reads performed by the query objects are non-blocking (WAL
/// mode allows concurrent reads). Writes still go through the ``MymeClient``
/// namespace APIs (``ItemsNamespace``, etc.), which keep the local store in
/// sync and, in synced mode, enqueue mutations for the server.
///
/// - Important: `MymeStore` must be created and used on the `@MainActor`.
///   It is safe to pass the store to `@Observable @MainActor` SwiftUI views.
@Observable
@MainActor
public final class MymeStore {

    // MARK: - Internal

    private let pool: DatabasePool

    // MARK: - Init

    init(pool: DatabasePool) {
        self.pool = pool
    }

    // MARK: - Item queries

    /// Creates a live query over all items matching `filters`.
    ///
    /// The returned ``ItemQuery`` starts fetching immediately. Its `items`
    /// property is updated on the main actor whenever matching rows change.
    ///
    ///     let query = store.query()                          // all items
    ///     let notes = store.query(filters: .init(type: "core.note"))
    ///     let active = store.query(filters: .init(state: .active))
    public func query(filters: ListFilters? = nil) -> ItemQuery {
        ItemQuery(pool: pool, filters: filters)
    }

    /// Creates a live query over a single item by `id`.
    ///
    /// `query.item` is `nil` if the item doesn't exist or has been purged.
    public func queryItem(id: String) -> SingleItemQuery {
        SingleItemQuery(pool: pool, id: id)
    }

    /// Creates a live, typed query for items of a specific domain-model type.
    ///
    ///     let query = store.typedQuery(CoreNote.self)
    ///     // query.items is [CoreNote]
    ///
    /// - Parameters:
    ///   - type: The ``MymeItem`` conforming type (e.g. `CoreNote.self`).
    ///   - filters: Additional filters (state, limit). The `type` filter is
    ///     derived automatically from `T.typeIdentifier`.
    public func typedQuery<T: MymeItem>(
        _ type: T.Type,
        filters: ListFilters? = nil
    ) -> TypedItemQuery<T> {
        TypedItemQuery(pool: pool, filters: filters)
    }

    // MARK: - Edge queries

    /// Creates a live query over outbound edges from `sourceId`.
    ///
    ///     let outbound = store.queryEdges(from: item.id)
    ///     let aboutEdges = store.queryEdges(from: item.id, edgeType: "about")
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
        EdgesQuery(pool: pool, sourceId: sourceId, edgeType: edgeType, limit: limit)
    }

    /// Creates a live query over **all edges of a given type** across the
    /// entire local store. Backs taxonomy-style "every reply", "every
    /// annotation" surfaces — replaces the walk-every-item polling that
    /// app authors were writing as a workaround.
    ///
    ///     let allReplies = store.queryEdges(ofType: "in-thread")
    ///
    /// - Parameters:
    ///   - edgeType: Edge type to track.
    ///   - limit: Optional row cap.
    public func queryEdges(
        ofType edgeType: String,
        limit: Int? = nil
    ) -> EdgesQuery {
        EdgesQuery(pool: pool, edgeType: edgeType, limit: limit)
    }

    /// Creates a live query over **inbound edges for a batch of targets**.
    /// See ``BackrefsQuery``. Duplicate IDs are collapsed; unknown IDs
    /// remain present in the result keyed to an empty array.
    ///
    ///     let backrefs = store.queryBackrefs(to: items.map(\.id), edgeType: "in-thread")
    ///     Text("\(backrefs.edgesByTarget[item.id]?.count ?? 0) replies")
    ///
    /// - Parameters:
    ///   - targetIds: Item IDs whose inbound edges should be tracked.
    ///   - edgeType: Restrict to this edge type, or `nil` for all.
    ///   - limit: Optional cap per target.
    public func queryBackrefs(
        to targetIds: [String],
        edgeType: String? = nil,
        limit: Int? = nil
    ) -> BackrefsQuery {
        BackrefsQuery(pool: pool, targetIds: targetIds, edgeType: edgeType, limit: limit)
    }

    // MARK: - Tag queries

    /// Creates a live query over tag usage across the local store.
    /// See ``TagsQuery``. Emits `[TagWithCount]` sorted count DESC, tag ASC
    /// — identical to the one-shot ``MetadataNamespace/listTags()`` and
    /// the server's `GET /metadata/tags`.
    ///
    ///     let tags = store.queryTags()
    ///     ForEach(tags.tags, id: \.tag) { entry in
    ///         TagChip(entry.tag, count: entry.count)
    ///     }
    public func queryTags() -> TagsQuery {
        TagsQuery(pool: pool)
    }
}
