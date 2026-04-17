import Foundation
import GRDB
import Observation

// MARK: - ItemQuery

/// A live, observable query over a filtered set of items in the local store.
///
/// `ItemQuery` holds a GRDB `ValueObservation` against the `items` table.
/// When any row that satisfies `filters` changes — insert, update, or delete —
/// the observation fires and ``items`` is updated on the main actor, which
/// propagates the change through `@Observable` to any SwiftUI view that reads
/// `query.items`.
///
/// ## Usage
///
///     let query = store.query(filters: ListFilters(type: "core.note"))
///     // In SwiftUI:
///     ForEach(query.items) { item in ... }
///
/// The observation is active for as long as the `ItemQuery` instance is alive.
/// Release the query (or call ``stop()``) to tear down the observer.
///
/// - Note: Reads are always served from the local SQLite cache. In synced
///   mode, the ``SyncEngine`` keeps the cache fresh in the background.
@Observable
@MainActor
public final class ItemQuery {

    // MARK: - Published state

    /// The current set of items matching the query's filters.
    /// Updated automatically whenever the underlying data changes.
    public private(set) var items: [Item] = []

    /// Whether the initial fetch has completed. `false` while the first
    /// result is still in flight from the background reader.
    public private(set) var isLoading: Bool = true

    /// The most recent error thrown by the observation, if any.
    public private(set) var error: Error?

    // MARK: - Internals

    // AnyDatabaseCancellable cancels the observation on dealloc — no need for deinit.
    private var cancellable: AnyDatabaseCancellable?

    // MARK: - Init

    init(pool: DatabasePool, filters: ListFilters?) {
        let observation = ValueObservation.tracking { db -> [ItemRecord] in
            var query = ItemRecord.all()

            if let type = filters?.type {
                query = query.filter(Column("type") == type)
            }
            if let state = filters?.state {
                query = query.filter(Column("state") == state.rawValue)
            }
            if let since = filters?.since {
                query = query.filter(Column("updated_at") >= since)
            }
            if let until = filters?.until {
                query = query.filter(Column("updated_at") <= until)
            }
            if let limit = filters?.limit {
                query = query.limit(limit)
            }
            query = query.order(Self.orderExpression(for: filters))
            return try query.fetchAll(db)
        }

        // .mainActor scheduler (GRDB 7) runs callbacks under @MainActor isolation,
        // making @Observable property assignments sound in Swift 6.
        cancellable = observation.start(
            in: pool,
            scheduling: .mainActor,
            onError: { [weak self] error in
                self?.error = error
                self?.isLoading = false
            },
            onChange: { [weak self] records in
                self?.items = records.compactMap { try? $0.toItem() }
                self?.isLoading = false
                self?.error = nil
            }
        )
    }

    // MARK: - Lifecycle

    /// Stops the observation and releases the database watcher.
    /// After calling `stop()`, `items` will no longer update.
    public func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    /// Order expression honoring `filters.sort` / `filters.direction`. Default
    /// is `updated_at DESC`, matching the server-side default for `GET /items`.
    nonisolated static func orderExpression(for filters: ListFilters?) -> SQLOrderingTerm {
        let column = Column(filters?.sort?.rawValue ?? "updated_at")
        return filters?.direction == .ascending ? column.asc : column.desc
    }
}

// MARK: - TypedItemQuery

/// A live, observable query over a filtered set of typed domain model items.
///
/// Works like ``ItemQuery`` but returns domain-model wrappers (e.g. `CoreNote`)
/// rather than raw `Item` values. Items that fail `T.init?(from:)` are silently
/// dropped — typically because the required fields are absent.
///
/// ## Usage
///
///     let query = store.typedQuery(CoreNote.self)
///     ForEach(query.items) { note in Text(note.body) }
@Observable
@MainActor
public final class TypedItemQuery<T: MymeItem> {

    // MARK: - Published state

    /// The current set of typed items. Updated automatically on change.
    public private(set) var items: [T] = []

    /// `true` while the initial fetch is in flight.
    public private(set) var isLoading: Bool = true

    /// Most recent observation error.
    public private(set) var error: Error?

    // MARK: - Internals

    private var cancellable: AnyDatabaseCancellable?

    // MARK: - Init

    init(pool: DatabasePool, filters: ListFilters? = nil) {
        let typeId = T.typeIdentifier
        let observation = ValueObservation.tracking { db -> [ItemRecord] in
            var query = ItemRecord.filter(Column("type") == typeId)
            if let state = filters?.state {
                query = query.filter(Column("state") == state.rawValue)
            }
            if let limit = filters?.limit {
                query = query.limit(limit)
            }
            query = query.order(ItemQuery.orderExpression(for: filters))
            return try query.fetchAll(db)
        }

        cancellable = observation.start(
            in: pool,
            scheduling: .mainActor,
            onError: { [weak self] error in
                self?.error = error
                self?.isLoading = false
            },
            onChange: { [weak self] records in
                self?.items = records.compactMap { record in
                    guard let item = try? record.toItem() else { return nil }
                    return T(from: item)
                }
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
