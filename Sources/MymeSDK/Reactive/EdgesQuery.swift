import Foundation
import GRDB

// MARK: - EdgesQuery

/// A live, observable query over edges from a source item.
///
/// The observation fires whenever any edge whose `source_id` equals `sourceId`
/// changes — create, update, or delete.
///
/// ## Usage
///
///     let query = store.queryEdges(from: item.id, edgeType: "about")
///     ForEach(query.edges) { edge in ... }
@Observable
@MainActor
public final class EdgesQuery {

    // MARK: - Published state

    /// Current list of edges, in creation order. Updated automatically.
    public private(set) var edges: [Edge] = []

    /// `true` while the initial fetch is in flight.
    public private(set) var isLoading: Bool = true

    /// Most recent observation error.
    public private(set) var error: Error?

    // MARK: - Internals

    private var cancellable: AnyDatabaseCancellable?

    // MARK: - Init

    /// Creates a live outbound-edge query.
    ///
    /// - Parameters:
    ///   - pool: Shared ``DatabasePool`` from the ``LocalStore``.
    ///   - sourceId: ID of the source item.
    ///   - edgeType: Restrict to this edge type, or `nil` for all types.
    ///   - limit: Optional cap on the result count.
    init(pool: DatabasePool, sourceId: String, edgeType: String?, limit: Int?) {
        let observation = ValueObservation.tracking { db -> [EdgeRecord] in
            var query = EdgeRecord
                .filter(Column("source_id") == sourceId)
                .order(Column("created_at").asc)
            if let edgeType {
                query = query.filter(Column("edge_type") == edgeType)
            }
            if let limit {
                query = query.limit(limit)
            }
            return try query.fetchAll(db)
        }

        cancellable = observation.start(
            in: pool,
            scheduling: .mainQueue,
            onError: { [weak self] error in
                self?.error = error
                self?.isLoading = false
            },
            onChange: { [weak self] records in
                self?.edges = records.compactMap { try? $0.toEdge() }
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

    deinit {
        cancellable?.cancel()
    }
}
