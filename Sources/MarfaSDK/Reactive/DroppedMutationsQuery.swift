import Foundation
import Observation
import SwiftData

// MARK: - Predicate safety
//
// See `Sources/MarfaSDK/LocalStore/Schema/PredicateConventions.swift`.
// Every column on ``DroppedMutationModel`` referenced here is a stored
// `String` or `Int`; the descriptor below sorts on `droppedAt` (an ISO
// 8601 string with fractional seconds, fixed-width segments — correct
// lexicographic ordering under
// `Date.ISO8601FormatStyle(includingFractionalSeconds: true)`).

/// A live, observable view over the dropped-mutation log.
///
/// Tracks every ``DroppedMutationRecord`` persisted by ``SyncEngine``: a
/// queued mutation that hit a failure no retry can clear, and every entry a
/// bulk call reached the server with and had refused. The second kind
/// carries `errorStatus == 0`, because the call itself succeeded and the
/// entry's refusal never had a status of its own. Refreshes whenever any
/// `ModelContext.save()` fires — `recordDropped`, the cascade insert,
/// and the dismissal APIs all share the same `didSave` subscription
/// the other reactive queries use.
///
/// ## Usage
///
///     if let query = store.queryDroppedMutations() {
///         List(query.dropped) { row in
///             DroppedRow(record: row)
///                 .swipeActions {
///                     Button("Dismiss") {
///                         Task { try? await store.dismissDropped(id: row.id) }
///                     }
///                 }
///         }
///     }
///
/// Vended by ``MarfaStore/queryDroppedMutations()``. Returns `nil`
/// for pure-local clients without a sync engine — those modes never
/// drop mutations, so the log would never grow.
///
/// Sort order: ``DroppedMutationRecord/droppedAt`` descending (newest
/// first). Same ordering as the underlying `MutationQueue.fetchDropped`.
@Observable
@MainActor
public final class DroppedMutationsQuery {

    // MARK: - Published state

    /// Every dropped mutation row, newest first. Empty when nothing
    /// has been dropped or every row has been dismissed.
    public private(set) var dropped: [DroppedMutationRecord] = []

    /// Whether the initial fetch has completed. `false` until the
    /// first result lands.
    public private(set) var isLoading: Bool = true

    /// The most recent error thrown by the observation, if any.
    public private(set) var error: Error?

    /// Convenience: `true` when no rows are present.
    public var isEmpty: Bool { dropped.isEmpty }

    // MARK: - Internals

    private let context: ModelContext
    private var observer: RefetchObserver?

    // MARK: - Init

    init(container: ModelContainer) {
        self.context = ModelContext(container)
        Task { @MainActor [weak self] in self?.refetch() }
        self.observer = RefetchObserver { [weak self] in self?.refetch() }
    }

    // MARK: - Refetch

    private func refetch() {
        do {
            var descriptor = FetchDescriptor<DroppedMutationModel>(
                sortBy: [SortDescriptor(\.droppedAt, order: .reverse)]
            )
            descriptor.fetchLimit = .max
            let models = try context.fetch(descriptor)
            self.dropped = models.map { $0.toRecord() }
            self.isLoading = false
            self.error = nil
        } catch {
            self.error = error
            self.isLoading = false
        }
    }

    // MARK: - Lifecycle

    /// Stops the observation and releases the database watcher. After
    /// calling `stop()`, ``dropped`` will no longer update.
    public func stop() {
        observer?.cancel()
        observer = nil
    }
}
