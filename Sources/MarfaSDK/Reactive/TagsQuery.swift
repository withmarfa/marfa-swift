import Foundation
import Observation
import SwiftData

// MARK: - Predicate safety
//
// See `Sources/MarfaSDK/LocalStore/Schema/PredicateConventions.swift`.
// Predicate reaches through the `item` relationship to compare
// `stateRaw` (rule 3 allows traversal via `@Relationship`). `tagsData`
// is opaque to the predicate engine; aggregation is performed in Swift
// over the JSON-decoded accessor.

// MARK: - TagsQuery

/// A live, observable query over tag usage across the local store.
///
/// Emits `[TagWithCount]` sorted count DESC, tag ASC — same ordering
/// as the server's `GET /metadata/tags` and the one-shot
/// ``MetadataNamespace/listTags()``. Re-runs whenever any metadata
/// or parent-item row changes.
///
/// ## Usage
///
///     let query = store.queryTags()
///     ForEach(query.tags, id: \.tag) { entry in
///         TagChip(entry.tag, count: entry.count)
///     }
@Observable
@MainActor
public final class TagsQuery {

    // MARK: - Published state

    public private(set) var tags: [TagWithCount] = []
    public private(set) var isLoading: Bool = true
    public private(set) var error: Error?

    // MARK: - Internals

    private let context: ModelContext
    private var observer: RefetchObserver?

    // MARK: - Init

    init(container: ModelContainer) {
        self.context = ModelContext(container)
        Task { @MainActor [weak self] in self?.refetch() }
        self.observer = RefetchObserver { [weak self] in self?.refetch() }
    }

    private func refetch() {
        do {
            let trashedRaw = ItemState.trashed.rawValue
            // Single-expression predicate (the macro requires one
            // expression). Orphan rows (`item == nil`) are excluded by
            // the explicit nil-check.
            let predicate = #Predicate<MarfaMetadataModel> { meta in
                meta.item != nil && meta.item?.stateRaw != trashedRaw
            }
            var descriptor = FetchDescriptor<MarfaMetadataModel>(predicate: predicate)
            // Fault the parent item alongside the metadata rows so the
            // predicate engine doesn't pay a per-row materialisation
            // cost when walking the relationship.
            descriptor.relationshipKeyPathsForPrefetching = [\.item]
            let models = try context.fetch(descriptor)
            var counts: [String: Int] = [:]
            for model in models {
                for tag in model.tags {
                    counts[tag, default: 0] += 1
                }
            }
            self.tags = counts
                .map { TagWithCount(tag: $0.key, count: $0.value) }
                .sorted { lhs, rhs in
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    return lhs.tag < rhs.tag
                }
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
