import Foundation
import Observation
import SwiftData

// MARK: - Predicate safety
//
// See `Sources/MarfaSDK/LocalStore/Schema/PredicateConventions.swift`.
// This query owns no predicates. Both the fetch and the text scan live
// on ``LocalStore/searchItems(text:filters:)``, which is where the
// conventions are enforced.

// MARK: - SearchQuery

/// A live, observable local search over item `title` and `body`.
///
/// `SearchQuery` differs from every other reactive query in one
/// deliberate way: it does **not** do its work on the main actor. A
/// search decodes the `properties` JSON of every candidate row to read
/// its text, which is far too much to run inline in a view update, so
/// the whole scan is handed to the ``LocalStore`` actor and the main
/// actor is touched only to publish the finished results.
///
/// Semantics, ranking, the result cap, and the known divergences from
/// the server's `GET /search` are all documented on
/// ``LocalStore/searchItems(text:filters:)`` — read that before
/// swapping a screen from remote search to this.
///
/// ## Usage
///
///     let hits = store.querySearch(text: term, filters: SearchFilters(type: "core.note"))
///     ForEach(hits.results, id: \.item.id) { hit in
///         NoteRow(hit.item)
///     }
///
/// The query re-runs whenever the store saves, debounced on the same
/// ``RefreshDebounce/interval`` as every other reactive query, so
/// results stay live as sync lands new rows. The search term is fixed
/// for the life of the query — for search-as-you-type, create a new
/// query per term and ``stop()`` the previous one.
@Observable
@MainActor
public final class SearchQuery {

    // MARK: - Published state

    /// Current matches, ordered relevance DESC. Empty until the first
    /// scan lands, and empty for a blank search term.
    public private(set) var results: [SearchResult] = []

    /// Whether the initial scan has completed. `false` once the first
    /// result set (or error) lands.
    public private(set) var isLoading: Bool = true

    /// The most recent error thrown by a scan, if any.
    public private(set) var error: Error?

    // MARK: - Internals

    private let store: LocalStore
    private let text: String
    private let filters: SearchFilters?
    private var searchTask: Task<Void, Never>?
    private var observer: RefetchObserver?

    // MARK: - Init

    init(store: LocalStore, text: String, filters: SearchFilters?) {
        self.store = store
        self.text = text
        self.filters = filters
        scheduleSearch()
        self.observer = RefetchObserver { [weak self] in self?.scheduleSearch() }
    }

    // MARK: - Search

    /// Cancels any scan still in flight before starting the next one, so
    /// a burst of saves can't land results out of order.
    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        do {
            let hits = try await store.searchItems(text: text, filters: filters)
            guard !Task.isCancelled else { return }
            self.results = hits
            self.isLoading = false
            self.error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error
            self.isLoading = false
        }
    }

    // MARK: - Lifecycle

    /// Stops the observation and cancels any scan in flight. After
    /// calling `stop()`, `results` will no longer update.
    public func stop() {
        searchTask?.cancel()
        searchTask = nil
        observer?.cancel()
        observer = nil
    }
}
