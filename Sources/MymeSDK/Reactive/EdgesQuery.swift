import Foundation
import Observation
import SwiftData

// MARK: - Predicate safety
//
// See `Sources/MymeSDK/LocalStore/Schema/PredicateConventions.swift`.
// Predicates compare against stored String columns `sourceId`,
// `targetId`, `edgeType`. The captured-value short-circuit pattern
// (rule 8) handles the optional `edgeType` filter.

// MARK: - EdgesQuery

/// A live, observable query over edges from a source item or by type.
///
/// Two factory variants:
/// - **Outbound**: ``MymeStore/queryEdges(from:edgeType:limit:)`` — all
///   edges where `sourceId` matches.
/// - **By type only**: ``MymeStore/queryEdges(ofType:limit:)`` —
///   tenant-scoped, every edge of a given type.
///
/// Sorted by `createdAt` ascending. Updated on every applicable
/// `ModelContext.didSave`.
///
/// ## Usage
///
///     let query = store.queryEdges(from: item.id, edgeType: "about")
///     ForEach(query.edges) { edge in ... }
@Observable
@MainActor
public final class EdgesQuery {

    // MARK: - Published state

    public private(set) var edges: [Edge] = []
    public private(set) var isLoading: Bool = true
    public private(set) var error: Error?

    // MARK: - Internals

    private let context: ModelContext
    private let sourceId: String?
    private let edgeType: String?
    private let limit: Int?
    private var observer: RefetchObserver?

    // MARK: - Init (outbound)

    init(container: ModelContainer, sourceId: String, edgeType: String?, limit: Int?) {
        self.context = ModelContext(container)
        self.sourceId = sourceId
        self.edgeType = edgeType
        self.limit = limit
        Task { @MainActor [weak self] in self?.refetch() }
        self.observer = RefetchObserver { [weak self] in self?.refetch() }
    }

    // MARK: - Init (by type only)

    init(container: ModelContainer, edgeType: String, limit: Int? = nil) {
        self.context = ModelContext(container)
        self.sourceId = nil
        self.edgeType = edgeType
        self.limit = limit
        Task { @MainActor [weak self] in self?.refetch() }
        self.observer = RefetchObserver { [weak self] in self?.refetch() }
    }

    // MARK: - Refetch

    private func refetch() {
        do {
            let sourceFilter = sourceId ?? ""
            let hasSourceFilter = sourceId != nil
            let typeFilter = edgeType ?? ""
            let hasTypeFilter = edgeType != nil
            let predicate = #Predicate<MymeEdgeModel> { edge in
                (!hasSourceFilter || edge.sourceId == sourceFilter) &&
                (!hasTypeFilter   || edge.edgeType == typeFilter)
            }
            var descriptor = FetchDescriptor<MymeEdgeModel>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
            if let limit { descriptor.fetchLimit = limit }
            let models = try context.fetch(descriptor)
            self.edges = models.map { $0.toWireEdge() }
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
