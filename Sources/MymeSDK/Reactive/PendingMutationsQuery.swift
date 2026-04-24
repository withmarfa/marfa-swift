import Foundation
import Observation
import SwiftData

// MARK: - Predicate safety
//
// See `Sources/MymeSDK/LocalStore/Schema/PredicateConventions.swift`.
// Every predicate-relevant column on `PendingMutationModel` is a
// stored `String` or `Int`; there are no `isEmpty` comparisons, no
// Codable-enum predicates, and no reserved-name collisions.

// MARK: - PendingMutationStatus

/// Consumer-facing status projection of a queued mutation.
///
/// Derived from the persisted `(state, attemptCount, lastError)` tuple
/// — `PendingMutationsQuery` computes this on every refresh rather
/// than persisting it separately, so the query always reads the
/// freshest state.
public enum PendingMutationStatus: Sendable, Equatable {
    /// Queued, not yet attempted.
    case pending

    /// The sync engine is currently issuing the transport call for this
    /// record. Set by ``MutationQueue/markInFlight(id:)`` just before
    /// the network request.
    case inFlight

    /// A transient replay failed; the engine will retry on the next
    /// drain cycle. `attemptCount` reports how many attempts have
    /// failed so far; `lastError` is the most recent error message.
    case retrying(attemptCount: Int, lastError: String)
}

// MARK: - PendingMutationSummary

/// Sendable snapshot of a queued mutation for consumer use. Wraps the
/// ``PendingMutationRecord`` DTO with a projected
/// ``PendingMutationStatus`` so consumer UX renders directly off the
/// summary without having to interpret `state` / `attemptCount` /
/// `lastError` pairs themselves.
public struct PendingMutationSummary: Sendable, Identifiable, Equatable {
    /// Stable queue id (UUIDv4). Matches
    /// ``PendingMutationRecord/id``; re-uses the same identifier so
    /// consumers can cross-reference between the summary and any
    /// raw-record APIs they already use.
    public let id: String

    /// The mutation kind (`createItem`, `setMetadata`, `uploadBlob`,
    /// etc.). Same `rawValue` as ``SyncEvent/mutationDropped``'s
    /// `kind` field.
    public let kind: MutationKind

    /// The local item/edge id this mutation targets, if any.
    /// Projection of ``PendingMutationRecord/localId``.
    public let itemId: String?

    /// ISO 8601 enqueue timestamp with fractional seconds. Same
    /// ordering the queue uses internally.
    public let createdAt: String

    /// Projected status. Use this instead of directly inspecting
    /// `state` / `attemptCount` / `lastError`.
    public let status: PendingMutationStatus

    public init(
        id: String,
        kind: MutationKind,
        itemId: String?,
        createdAt: String,
        status: PendingMutationStatus
    ) {
        self.id = id
        self.kind = kind
        self.itemId = itemId
        self.createdAt = createdAt
        self.status = status
    }

    /// Projects a ``PendingMutationRecord`` DTO into the consumer-facing
    /// summary. The mapping rule:
    ///
    /// - `state == .inFlight` → `.inFlight`
    /// - `state == .pending && attemptCount == 0` → `.pending`
    /// - `state == .pending && attemptCount > 0` → `.retrying(...)`
    ///   (carries the most recent `lastError`; defaults to an empty
    ///   string if the error message was never persisted)
    public static func make(from record: PendingMutationRecord) -> PendingMutationSummary {
        let status: PendingMutationStatus
        switch record.state {
        case .inFlight:
            status = .inFlight
        case .pending:
            if record.attemptCount > 0 {
                status = .retrying(
                    attemptCount: record.attemptCount,
                    lastError: record.lastError ?? ""
                )
            } else {
                status = .pending
            }
        }
        return PendingMutationSummary(
            id: record.id,
            kind: record.kind,
            itemId: record.localId,
            createdAt: record.createdAt,
            status: status
        )
    }
}

// MARK: - PendingMutationsQuery

/// A live, observable query over the pending-mutation queue.
///
/// Tracks every queued mutation with its projected
/// ``PendingMutationStatus``. Refetches whenever any SwiftData
/// `ModelContext.save()` fires — the engine's `markInFlight`, the
/// enqueue helpers, `recordFailure`, and `remove` all trigger a
/// refresh through the same `didSave` subscription the other reactive
/// queries use.
///
/// ## Usage
///
///     if let query = store.queryPendingMutations() {
///         ForEach(query.mutations) { mutation in
///             row(for: mutation)
///         }
///     }
///
/// Vended by ``MymeStore/queryPendingMutations()``. Returns `nil`
/// for network-only clients that have no mutation queue — same
/// contract as other sync-specific surfaces.
@Observable
@MainActor
public final class PendingMutationsQuery {

    // MARK: - Published state

    /// Every queued mutation sorted by `createdAt` ascending. Empty
    /// when the queue is drained or the initial fetch has not yet
    /// completed.
    public private(set) var mutations: [PendingMutationSummary] = []

    /// Whether the initial fetch has completed. `false` until the
    /// first result lands.
    public private(set) var isLoading: Bool = true

    /// The most recent error thrown by the observation, if any.
    public private(set) var error: Error?

    /// Convenience mirror of ``SyncEngine/hasPendingMutations`` — the
    /// inverse. `true` when no mutations are queued.
    public var isEmpty: Bool { mutations.isEmpty }

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
            var descriptor = FetchDescriptor<PendingMutationModel>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
            descriptor.fetchLimit = .max
            let models = try context.fetch(descriptor)
            self.mutations = models.map { PendingMutationSummary.make(from: $0.toRecord()) }
            self.isLoading = false
            self.error = nil
        } catch {
            self.error = error
            self.isLoading = false
        }
    }

    // MARK: - Lifecycle

    /// Stops the observation and releases the database watcher. After
    /// calling `stop()`, `mutations` will no longer update.
    public func stop() {
        observer?.cancel()
        observer = nil
    }
}
