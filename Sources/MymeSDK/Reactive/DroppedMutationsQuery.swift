import Foundation
import Observation
import SwiftData

// MARK: - Predicate safety
//
// See `Sources/MymeSDK/LocalStore/Schema/PredicateConventions.swift`.
// This query doesn't predicate — it reads every row and relies on the
// descriptor's sort order, which is the predicate-safe path for a
// "list everything" fetch.

// MARK: - DroppedMutationsQuery

/// A live, observable query over the dropped-mutation log.
///
/// Emits `[DroppedMutationRecord]` ordered newest first (descending
/// `droppedAt`). Re-runs whenever any write to the `DroppedMutationModel`
/// table fires `ModelContext.didSave` — which happens on every new
/// permanent drop, every cascade drop, and every consumer-initiated
/// purge.
///
/// In pure-local and remote-only modes, the query publishes an empty
/// list — there's no mutation queue and therefore no dropped-mutation
/// log to observe.
///
/// ## Usage
///
///     let query = store.queryDroppedMutations()
///     List(query.dropped, id: \.id) { record in
///         HStack {
///             Text(record.kind.rawValue)
///             Spacer()
///             Text(record.errorMessage).foregroundStyle(.secondary)
///             Button("Dismiss") {
///                 Task { try? await client.syncEngine?.purgeDroppedMutation(id: record.id) }
///             }
///         }
///     }
@Observable
@MainActor
public final class DroppedMutationsQuery {

    // MARK: - Published state

    public private(set) var dropped: [DroppedMutationRecord] = []
    public private(set) var isLoading: Bool = true
    public private(set) var error: Error?

    // MARK: - Internals

    private let syncEngine: SyncEngine?
    private var observer: RefetchObserver?

    // MARK: - Init

    init(syncEngine: SyncEngine?) {
        self.syncEngine = syncEngine
        Task { @MainActor [weak self] in self?.refetch() }
        self.observer = RefetchObserver { [weak self] in self?.refetch() }
    }

    // MARK: - Refetch

    private func refetch() {
        guard let syncEngine else {
            self.dropped = []
            self.isLoading = false
            self.error = nil
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.dropped = try await syncEngine.droppedMutations()
                self.isLoading = false
                self.error = nil
            } catch {
                self.error = error
                self.isLoading = false
            }
        }
    }

    // MARK: - Lifecycle

    public func stop() {
        observer?.cancel()
        observer = nil
    }
}
