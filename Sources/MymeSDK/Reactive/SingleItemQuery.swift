import Foundation
import Observation
import SwiftData

// MARK: - Predicate safety
//
// See `Sources/MymeSDK/LocalStore/Schema/PredicateConventions.swift`.
// Predicate compares against the stored String column `id`.

// MARK: - SingleItemQuery

/// A live, observable query over a single item by ID.
///
/// The observation fires whenever the item row changes. If the item is
/// purged, ``item`` becomes `nil`.
///
/// ## Usage
///
///     let query = store.queryItem(id: item.id)
///     // In SwiftUI:
///     if let item = query.item { DetailView(item: item) }
@Observable
@MainActor
public final class SingleItemQuery {

    // MARK: - Published state

    /// The item, or `nil` if it has been purged or does not exist.
    public private(set) var item: Item?

    public private(set) var isLoading: Bool = true
    public private(set) var error: Error?

    // MARK: - Internals

    private let context: ModelContext
    private let id: String
    private var observer: RefetchObserver?

    // MARK: - Init

    init(container: ModelContainer, id: String) {
        self.context = ModelContext(container)
        self.id = id
        Task { @MainActor [weak self] in self?.refetch() }
        self.observer = RefetchObserver { [weak self] in self?.refetch() }
    }

    private func refetch() {
        do {
            let captured = id
            let predicate = #Predicate<MymeItemModel> { $0.id == captured }
            var descriptor = FetchDescriptor<MymeItemModel>(predicate: predicate)
            descriptor.fetchLimit = 1
            self.item = try context.fetch(descriptor).first?.toWireItem()
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
