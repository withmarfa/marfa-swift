import Foundation
import Observation
import SwiftData

// MARK: - PendingMutationsQuery

/// A live, observable query over the mutation queue.
///
/// Emits `[PendingMutationSnapshot]` ordered by `createdAt` (drain order).
/// Re-runs whenever the queue changes (enqueue, remove, recordFailure) OR
/// when ``SyncEngine`` reports a replay lifecycle transition (start / end
/// of in-flight). The combined trigger set catches in-flight transitions
/// that don't correspond to a queue write — a long-running network
/// replay that eventually fails or succeeds would otherwise only refetch
/// on the queue write, missing the pending → in-flight transition.
///
/// In pure-local mode (no ``SyncEngine``), the query publishes an empty
/// list — there's no queue to observe.
///
/// ## Usage
///
///     let query = store.queryPendingMutations()
///     List(query.mutations, id: \.id) { m in
///         HStack {
///             Text(m.kind.rawValue)
///             Spacer()
///             switch m.status {
///             case .pending: ProgressView().controlSize(.small)
///             case .inFlight: ProgressView()
///             case .failed(let err, _): Label(err, systemImage: "exclamationmark.triangle")
///             }
///         }
///     }
@Observable
@MainActor
public final class PendingMutationsQuery {

    // MARK: - Published state

    public private(set) var mutations: [PendingMutationSnapshot] = []
    public private(set) var isLoading: Bool = true
    public private(set) var error: Error?

    // MARK: - Internals

    private let syncEngine: SyncEngine?
    private var observer: RefetchObserver?
    private var lifecycleTask: Task<Void, Never>?

    // MARK: - Init

    init(syncEngine: SyncEngine?) {
        self.syncEngine = syncEngine
        // Initial fetch kicked off on the next main-actor tick so the
        // query object returns fully initialised before any async work runs.
        Task { @MainActor [weak self] in self?.refetch() }
        // Queue-state changes (enqueue, remove, recordFailure) fire didSave.
        self.observer = RefetchObserver { [weak self] in self?.refetch() }
        // In-flight transitions are ephemeral and don't fire didSave.
        if let syncEngine {
            let stream = syncEngine.mutationLifecycleEvents
            self.lifecycleTask = Task { [weak self] in
                for await _ in stream {
                    if Task.isCancelled { return }
                    Task { @MainActor [weak self] in self?.refetch() }
                }
            }
        }
    }

    // MARK: - Refetch

    private func refetch() {
        guard let syncEngine else {
            // Pure-local mode or remote-only client — no queue, no snapshots.
            self.mutations = []
            self.isLoading = false
            self.error = nil
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshots = try await syncEngine.pendingMutations()
                self.mutations = snapshots
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
        lifecycleTask?.cancel()
        lifecycleTask = nil
    }
}
