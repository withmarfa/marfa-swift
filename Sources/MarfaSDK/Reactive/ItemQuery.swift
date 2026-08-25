import Foundation
import Observation
import SwiftData

// MARK: - Predicate safety
//
// See `Sources/MarfaSDK/LocalStore/Schema/PredicateConventions.swift`.
// Filters use the captured-value short-circuit pattern (rule 8) to
// compose predicates without runtime `Predicate<T>` composition. State
// is compared against `stateRaw` (rule 7), never against `.active`
// directly.

// MARK: - ItemQuery

/// A live, observable query over a filtered set of items in the local
/// store.
///
/// `ItemQuery` opens its own `ModelContext` on `@MainActor`, subscribes
/// to `ModelContext.didSave`, and refetches after a 50 ms debounce
/// window (see ``RefreshDebounce``) — the same coalescing strategy
/// every reactive query uses.
///
/// ## Usage
///
///     let query = store.query(filters: ListFilters(type: "core.note"))
///     // In SwiftUI:
///     ForEach(query.items) { item in ... }
///
/// The observation is active for as long as the `ItemQuery` instance is
/// alive. Release the query (or call ``stop()``) to tear down the
/// observer.
@Observable
@MainActor
public final class ItemQuery {

    // MARK: - Published state

    /// The current set of items matching the query's filters. Updated
    /// automatically whenever the underlying data changes.
    public private(set) var items: [Item] = []

    /// Whether the initial fetch has completed. `false` until the first
    /// result lands.
    public private(set) var isLoading: Bool = true

    /// The most recent error thrown by the observation, if any.
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

    // MARK: - Refetch

    private func refetch() {
        do {
            // Through the shared selector rather than the raw descriptor.
            // A `tags` filter cannot narrow a fetch, so it is applied after a
            // metadata join inside `itemModels`; going straight to the
            // descriptor here would accept `tags` and quietly ignore it.
            let models = try LocalStore.itemModels(in: context, for: filters).rows
            self.items = models.map { $0.toWireItem() }
            self.isLoading = false
            self.error = nil
        } catch {
            self.error = error
            self.isLoading = false
        }
    }

    // MARK: - Lifecycle

    /// Stops the observation and releases the database watcher. After
    /// calling `stop()`, `items` will no longer update.
    public func stop() {
        observer?.cancel()
        observer = nil
    }
}

// MARK: - TypedItemQuery

/// A live, observable query over a filtered set of typed domain model
/// items.
///
/// Works like ``ItemQuery`` but returns domain-model wrappers (e.g.
/// `CoreNote`) rather than raw `Item` values. Items that fail
/// `T.init?(from:)` are silently dropped — typically because the
/// required fields are absent.
///
/// ## Usage
///
///     let query = store.typedQuery(CoreNote.self)
///     ForEach(query.items) { note in Text(note.body) }
@Observable
@MainActor
public final class TypedItemQuery<T: MarfaItem> {

    // MARK: - Published state

    public private(set) var items: [T] = []
    public private(set) var isLoading: Bool = true
    public private(set) var error: Error?

    // MARK: - Internals

    private let context: ModelContext
    private let filters: ListFilters?
    private var observer: RefetchObserver?

    // MARK: - Init

    init(container: ModelContainer, filters: ListFilters? = nil) {
        self.context = ModelContext(container)
        // Force the type filter onto the descriptor so the predicate
        // narrows by `type == T.typeIdentifier` even when the caller
        // didn't pass one.
        var withType = filters ?? ListFilters()
        withType.type = T.typeIdentifier
        self.filters = withType
        Task { @MainActor [weak self] in self?.refetch() }
        self.observer = RefetchObserver { [weak self] in self?.refetch() }
    }

    private func refetch() {
        do {
            // Shared selector, for the reason given in `ItemQuery.refetch`.
            let models = try LocalStore.itemModels(in: context, for: filters).rows
            self.items = models.compactMap { T(from: $0.toWireItem()) }
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
