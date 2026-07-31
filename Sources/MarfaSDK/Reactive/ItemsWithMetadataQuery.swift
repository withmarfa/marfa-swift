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
            let descriptor = LocalStore.makeItemsDescriptor(filters: filters)
            let itemModels = try context.fetch(descriptor)
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
                // Last write wins, matching what a later fetch returns anyway.
                metadataById = Dictionary(
                    metaModels.map { ($0.itemId, $0) },
                    uniquingKeysWith: { _, newer in newer }
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
