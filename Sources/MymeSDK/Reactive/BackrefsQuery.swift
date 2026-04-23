import Foundation
import Observation
import SwiftData

// MARK: - Predicate safety
//
// See `Sources/MymeSDK/LocalStore/Schema/PredicateConventions.swift`.
// `Set.contains` over a captured `[String]` is supported (rule 1
// caveat — captured collection literal contains() is allowed).

// MARK: - BackrefsQuery

/// A live, observable query over inbound edges for a batch of target
/// items.
///
/// `edgesByTarget` is keyed by every distinct target ID the query was
/// created with; unknown IDs stay present with an empty array so
/// callers can iterate the input without `??`-defaulting. Re-emits
/// whenever any edge whose `targetId` matches one of the watched IDs
/// changes — create, update, delete.
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
@Observable
@MainActor
public final class BackrefsQuery {

    // MARK: - Published state

    public private(set) var edgesByTarget: [String: [Edge]] = [:]
    public private(set) var isLoading: Bool = true
    public private(set) var error: Error?

    // MARK: - Internals

    private let context: ModelContext
    private let distinctIds: [String]
    private let initial: [String: [Edge]]
    private let edgeType: String?
    private let limit: Int?
    private var observer: RefetchObserver?

    // MARK: - Init

    init(
        container: ModelContainer,
        targetIds: [String],
        edgeType: String?,
        limit: Int?
    ) {
        self.context = ModelContext(container)
        self.distinctIds = Array(Set(targetIds))
        self.initial = Dictionary(uniqueKeysWithValues: distinctIds.map { ($0, [Edge]()) })
        self.edgeType = edgeType
        self.limit = limit

        // Empty input: bypass observation entirely. Callers iterating
        // over their input ids see an empty `edgesByTarget` and the
        // query is loaded.
        guard !distinctIds.isEmpty else {
            self.edgesByTarget = initial
            self.isLoading = false
            return
        }

        Task { @MainActor [weak self] in self?.refetch() }
        self.observer = RefetchObserver { [weak self] in self?.refetch() }
    }

    // MARK: - Refetch

    private func refetch() {
        do {
            let idSet = Set(distinctIds)
            let typeFilter = edgeType ?? ""
            let hasTypeFilter = edgeType != nil
            let predicate = #Predicate<MymeEdgeModel> { edge in
                idSet.contains(edge.targetId) &&
                (!hasTypeFilter || edge.edgeType == typeFilter)
            }
            let descriptor = FetchDescriptor<MymeEdgeModel>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
            let models = try context.fetch(descriptor)
            var grouped = initial
            for model in models {
                let edge = model.toWireEdge()
                grouped[edge.targetId, default: []].append(edge)
            }
            if let limit {
                for (key, edges) in grouped where edges.count > limit {
                    grouped[key] = Array(edges.prefix(limit))
                }
            }
            self.edgesByTarget = grouped
            self.isLoading = false
            self.error = nil
        } catch {
            self.error = error
            self.isLoading = false
        }
    }

    // MARK: - Lifecycle

    public func stop() {
        observer?.cancel()
        observer = nil
    }
}
