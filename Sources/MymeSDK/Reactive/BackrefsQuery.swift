import Foundation
import GRDB
import Observation

// MARK: - BackrefsQuery

/// A live, observable query over inbound edges for a batch of target items.
///
/// `edgesByTarget` is keyed by every distinct target ID the query was
/// created with; unknown IDs stay present with an empty array so callers can
/// iterate the input without `??`-defaulting. Re-emits whenever any edge
/// whose `target_id` matches one of the watched IDs changes — create,
/// update, delete.
///
/// ## Usage
///
///     let query = store.queryBackrefs(
///         to: items.map(\.id),
///         edgeType: "in-thread"
///     )
///     ForEach(items) { item in
///         Text("\(query.edgesByTarget[item.id]?.count ?? 0) replies")
///     }
///
/// Backs "reply count per message", "citations per article", and similar
/// batched backref surfaces without an N+1 per-item observation.
@Observable
@MainActor
public final class BackrefsQuery {

    // MARK: - Published state

    /// Current inbound edges, keyed by target ID. Updated automatically.
    public private(set) var edgesByTarget: [String: [Edge]] = [:]

    /// `true` while the initial fetch is in flight.
    public private(set) var isLoading: Bool = true

    /// Most recent observation error, if any.
    public private(set) var error: Error?

    // MARK: - Internals

    private var cancellable: AnyDatabaseCancellable?

    // MARK: - Init

    /// Creates a live backrefs query.
    ///
    /// Duplicates in `targetIds` are collapsed to distinct. An empty
    /// `targetIds` yields an empty dictionary and immediately marks the
    /// query as loaded.
    ///
    /// - Parameters:
    ///   - pool: Shared ``DatabasePool`` from the ``LocalStore``.
    ///   - targetIds: Item IDs whose inbound edges should be tracked.
    ///   - edgeType: Restrict to this edge type, or `nil` for all types.
    ///   - limit: Optional cap per target.
    init(
        pool: DatabasePool,
        targetIds: [String],
        edgeType: String?,
        limit: Int?
    ) {
        let distinct = Array(Set(targetIds))
        let initial = Dictionary(uniqueKeysWithValues: distinct.map { ($0, [Edge]()) })

        guard !distinct.isEmpty else {
            self.edgesByTarget = initial
            self.isLoading = false
            return
        }

        let observation = ValueObservation.tracking { db -> [String: [Edge]] in
            var request = EdgeRecord.filter(distinct.contains(Column("target_id")))
            if let edgeType {
                request = request.filter(Column("edge_type") == edgeType)
            }
            let records = try request.fetchAll(db)
            var result = initial
            for record in records {
                let edge = try record.toEdge()
                result[edge.targetId, default: []].append(edge)
            }
            if let limit {
                for (key, edges) in result where edges.count > limit {
                    result[key] = Array(edges.prefix(limit))
                }
            }
            return result
        }

        cancellable = observation.start(
            in: pool,
            scheduling: .mainActor,
            onError: { [weak self] error in
                self?.error = error
                self?.isLoading = false
            },
            onChange: { [weak self] grouped in
                self?.edgesByTarget = grouped
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
