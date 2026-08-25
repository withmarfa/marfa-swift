import Foundation
import Observation
import SwiftData

// MARK: - Predicate safety
//
// See `Sources/MarfaSDK/LocalStore/Schema/PredicateConventions.swift`.
// Items descriptor reuses ``LocalStore/makeItemsDescriptor(filters:)``
// (the same helper that powers `ItemQuery`); metadata fetch uses a
// captured `Set` over `itemId`.

// MARK: - ItemsWithMetadataQuery

/// A live, observable query over items paired with their metadata.
///
/// Emits `[ItemWithMetadata]` — the same composite the one-shot
/// ``ItemsNamespace/listWithMetadata(filters:)`` returns, but updated
/// automatically whenever any matching item or associated metadata row
/// changes (create, update, delete, tag add/remove, state transition).
///
/// Filtering, sorting, and `limit` mirror ``ItemQuery``. Items with no
/// metadata row fall back to empty ``Metadata``, matching the
/// one-shot's behavior.
@Observable
@MainActor
public final class ItemsWithMetadataQuery {

    // MARK: - Published state

    public private(set) var items: [ItemWithMetadata] = []
    public private(set) var isLoading: Bool = true
    public private(set) var error: Error?

    // MARK: - Internals

    private let context: ModelContext
    private let filters: ListFilters?
    private var observer: RefetchObserver?

    // MARK: - Init

    init(container: ModelContainer, filters: ListFilters?) {
        self.context = ModelContext(container)
        self.filters = filters
        Task { @MainActor [weak self] in self?.refetch() }
        self.observer = RefetchObserver { [weak self] in self?.refetch() }
    }

    private func refetch() {
        do {
            // Through the shared selector rather than the raw descriptor, so
            // a `tags` filter narrows here exactly as it does on the actor.
            // Tags cannot narrow a fetch, so they are applied after a
            // metadata join and the window with them; see `itemModels`.
            let itemModels = try LocalStore.itemModels(in: context, for: filters).rows
            let ids = Set(itemModels.map(\.id))
            let metadataById: [String: MarfaMetadataModel]
            if ids.isEmpty {
                metadataById = [:]
            } else {
                let metaPredicate = #Predicate<MarfaMetadataModel> { ids.contains($0.itemId) }
                let metaDescriptor = FetchDescriptor<MarfaMetadataModel>(predicate: metaPredicate)
                let metaModels = try context.fetch(metaDescriptor)
                // Duplicate `itemId` rows are constructible: the model is
                // indexed on it but carries no `#Unique`, which CloudKit
                // mirroring forbids, and two devices setting metadata on the
                // same item leave two rows. `uniqueKeysWithValues` would trap.
                // First row wins, matching `fetchMetadata` and
                // `writeMetadata`, which both take `.first` under a
                // `fetchLimit` of 1. A different choice renders one row here
                // and another in the detail view of the same item,
                // permanently. (This comment used to open by saying last
                // write wins, which is neither what the line below does nor
                // what the rest of the comment then said.)
                metadataById = Dictionary(
                    metaModels.map { ($0.itemId, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
            self.items = itemModels.map { model in
                let item = model.toWireItem()
                let metadata = metadataById[model.id]?.toWireMetadata()
                    ?? Metadata(extensions: [:], itemId: model.id, tags: [])
                return ItemWithMetadata(item: item, metadata: metadata)
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
