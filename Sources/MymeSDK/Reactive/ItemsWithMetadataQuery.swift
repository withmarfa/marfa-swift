import Foundation
import GRDB
import Observation

// MARK: - ItemsWithMetadataQuery

/// A live, observable query over items paired with their metadata.
///
/// Emits `[ItemWithMetadata]` — the same composite the one-shot
/// ``ItemsNamespace/listWithMetadata(filters:)`` returns, but updated
/// automatically whenever any matching `items` row or associated
/// `item_metadata` row changes (create, update, delete, tag add/remove,
/// state transition).
///
/// ## Usage
///
///     let query = store.queryItemsWithMetadata(filters: ListFilters(type: "core.note"))
///     ForEach(query.items, id: \.item.id) { pair in
///         NoteCard(item: pair.item, tags: pair.metadata.tags)
///     }
///
/// Use this instead of hand-rolling a cache on top of
/// ``ItemsNamespace/listWithMetadata(filters:)`` + ``SyncEngine/events``
/// when the UI needs per-item metadata (tags, favorite flag, extensions)
/// alongside the items themselves.
///
/// Filtering, sorting, and `limit` mirror ``ItemQuery``. Items with no
/// metadata row fall back to empty ``Metadata``, matching the one-shot's
/// behaviour.
///
/// Best suited for UI-scale data. For very large libraries prefer the
/// one-shot ``ItemsNamespace/listWithMetadata(filters:)`` — the observation
/// re-runs the full aggregation on every touched row in the watched tables.
@Observable
@MainActor
public final class ItemsWithMetadataQuery {

    // MARK: - Published state

    /// Current items with metadata. Updated automatically.
    public private(set) var items: [ItemWithMetadata] = []

    /// `true` while the initial fetch is in flight.
    public private(set) var isLoading: Bool = true

    /// Most recent observation error, if any.
    public private(set) var error: Error?

    // MARK: - Internals

    private var cancellable: AnyDatabaseCancellable?

    // MARK: - Init

    init(pool: DatabasePool, filters: ListFilters?) {
        let observation = ValueObservation.tracking { db -> [ItemWithMetadata] in
            var request = ItemRecord.all()
            if let type = filters?.type {
                request = request.filter(Column("type") == type)
            }
            if let state = filters?.state {
                request = request.filter(Column("state") == state.rawValue)
            }
            if let since = filters?.since {
                request = request.filter(Column("updated_at") >= since)
            }
            if let until = filters?.until {
                request = request.filter(Column("updated_at") <= until)
            }
            if let limit = filters?.limit {
                request = request.limit(limit)
            }
            request = request.order(ItemQuery.orderExpression(for: filters))

            let itemRecords = try request.fetchAll(db)
            let ids = itemRecords.map(\.id)
            let metadataRecords =
                ids.isEmpty
                ? []
                : try MetadataRecord
                    .filter(ids.contains(Column("item_id")))
                    .fetchAll(db)
            let metadataById = Dictionary(
                uniqueKeysWithValues: metadataRecords.map { ($0.itemId, $0) }
            )

            return try itemRecords.map { record in
                let item = try record.toItem()
                let metadata =
                    try metadataById[record.id]?.toMetadata()
                    ?? Metadata(extensions: [:], itemId: record.id, tags: [])
                return ItemWithMetadata(item: item, metadata: metadata)
            }
        }

        cancellable = observation.start(
            in: pool,
            scheduling: .mainActor,
            onError: { [weak self] error in
                self?.error = error
                self?.isLoading = false
            },
            onChange: { [weak self] pairs in
                self?.items = pairs
                self?.isLoading = false
                self?.error = nil
            }
        )
    }

    // MARK: - Lifecycle

    /// Stops the observation.
    public func stop() {
        cancellable?.cancel()
        cancellable = nil
    }
}
