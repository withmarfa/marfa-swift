import Foundation
import GRDB
import Observation

// MARK: - TagsQuery

/// A live, observable query over tag usage across the local store.
///
/// Emits `[TagWithCount]` sorted count DESC, tag ASC — same ordering as the
/// server's `GET /metadata/tags` and the one-shot
/// ``MetadataNamespace/listTags()``. Re-runs whenever any `items` or
/// `item_metadata` row changes (tag add/remove, item create/delete,
/// state transition).
///
/// ## Usage
///
///     let query = store.queryTags()
///     ForEach(query.tags, id: \.tag) { entry in
///         TagChip(entry.tag, count: entry.count)
///     }
///
/// Best suited for UI-scale data. For very large libraries prefer the
/// one-shot ``MetadataNamespace/listTags()`` — the observation re-runs the
/// full aggregation on every touched row (GRDB coalesces rapid writes, but
/// there is no LIMIT in the aggregation).
@Observable
@MainActor
public final class TagsQuery {

    // MARK: - Published state

    /// Current tag list, in canonical order. Updated automatically.
    public private(set) var tags: [TagWithCount] = []

    /// `true` while the initial fetch is in flight.
    public private(set) var isLoading: Bool = true

    /// Most recent observation error, if any.
    public private(set) var error: Error?

    // MARK: - Internals

    private var cancellable: AnyDatabaseCancellable?

    // MARK: - Init

    /// Creates a live tags query.
    ///
    /// - Parameter pool: Shared ``DatabasePool`` from the ``LocalStore``.
    init(pool: DatabasePool) {
        let observation = ValueObservation.tracking { db -> [TagWithCount] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT je.value AS tag, COUNT(*) AS count
                    FROM item_metadata m
                    JOIN items i ON i.id = m.item_id
                    JOIN json_each(m.tags_json) je
                    WHERE i.state != 'trashed'
                    GROUP BY je.value
                    ORDER BY count DESC, tag ASC
                    """
            )
            return rows.map {
                TagWithCount(tag: $0["tag"] as String, count: $0["count"] as Int)
            }
        }

        cancellable = observation.start(
            in: pool,
            scheduling: .mainActor,
            onError: { [weak self] error in
                self?.error = error
                self?.isLoading = false
            },
            onChange: { [weak self] tags in
                self?.tags = tags
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
