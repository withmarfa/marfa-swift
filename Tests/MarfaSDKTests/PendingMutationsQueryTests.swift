import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport
import SwiftData

/// Tests for ``PendingMutationsQuery`` — the reactive surface over the
/// pending-mutation queue.
@Suite("PendingMutationsQuery")
@MainActor
struct PendingMutationsQueryTests {

    /// Builds a MarfaStore-backed test fixture. Returns the store (for
    /// vending queries), the mutation queue (for enqueuing), and the
    /// shared container (so changes propagate through
    /// `ModelContext.didSave`).
    private func makeFixture() async throws -> (
        store: MarfaStore,
        queue: MutationQueue,
        container: ModelContainer
    ) {
        let (localStore, queue, container) = try await MarfaSDKTest.makeInMemoryStorePair()
        let store = MarfaStore(container: container, localStore: localStore)
        return (store, queue, container)
    }

    @Test("initial state is empty")
    func initialStateIsEmpty() async throws {
        let (store, _, _) = try await makeFixture()
        let query = store.queryPendingMutations()

        // Initial fetch races with the init Task that kicks off the
        // first refetch. Poll until the async init settles.
        try await waitUntil { !query.isLoading }
        #expect(query.mutations.isEmpty)
        #expect(query.isEmpty)
        query.stop()
    }

    @Test("enqueue projects to .pending status")
    func enqueueProjectsPending() async throws {
        let (store, queue, _) = try await makeFixture()
        let query = store.queryPendingMutations()

        try await queue.enqueueUpdateItem(id: "i-1", properties: ["body": .string("x")])

        try await waitUntil { query.mutations.count == 1 }
        let summary = query.mutations[0]
        #expect(summary.kind == .updateItem)
        #expect(summary.itemId == "i-1")
        #expect(summary.status == .pending)
        query.stop()
    }

    @Test("recordFailure projects to .retrying with attempt count and error")
    func recordFailureProjectsRetrying() async throws {
        let (store, queue, _) = try await makeFixture()
        let query = store.queryPendingMutations()

        try await queue.enqueueDeleteItem(id: "i-2")
        try await waitUntil { query.mutations.count == 1 }

        let id = query.mutations[0].id
        try await queue.recordFailure(id: id, error: "offline")

        try await waitUntil {
            if case .retrying = query.mutations.first?.status { return true }
            return false
        }
        let summary = try #require(query.mutations.first)
        if case let .retrying(attemptCount, lastError) = summary.status {
            #expect(attemptCount == 1)
            #expect(lastError == "offline")
        } else {
            Issue.record("expected .retrying status, got \(summary.status)")
        }
        query.stop()
    }

    @Test("markInFlight projects to .inFlight, recordFailure resets to .retrying")
    func markInFlightAndRevert() async throws {
        let (store, queue, _) = try await makeFixture()
        let query = store.queryPendingMutations()

        try await queue.enqueueUpdateItem(id: "i-3", properties: [:])
        try await waitUntil { query.mutations.count == 1 }
        let id = query.mutations[0].id

        try await queue.markInFlight(id: id)
        try await waitUntil { query.mutations.first?.status == .inFlight }

        // On transient failure the engine calls recordFailure which
        // reverts to .pending with attemptCount bumped — surfacing as
        // .retrying in the query projection.
        try await queue.recordFailure(id: id, error: "transient")
        try await waitUntil {
            if case .retrying = query.mutations.first?.status { return true }
            return false
        }
        query.stop()
    }

    @Test("remove drops the record from the query")
    func removeDropsFromQuery() async throws {
        let (store, queue, _) = try await makeFixture()
        let query = store.queryPendingMutations()

        try await queue.enqueueDeleteItem(id: "i-4")
        try await waitUntil { query.mutations.count == 1 }
        let id = query.mutations[0].id

        try await queue.remove(id: id)
        try await waitUntil { query.mutations.isEmpty }
        #expect(query.isEmpty)
        query.stop()
    }

    @Test("stop halts further refreshes")
    func stopHaltsFurtherRefreshes() async throws {
        let (store, queue, _) = try await makeFixture()
        let query = store.queryPendingMutations()
        try await waitUntil { !query.isLoading }

        query.stop()

        // After stop, a subsequent enqueue should not refresh the query.
        try await queue.enqueueDeleteItem(id: "i-5")
        try await Task.sleep(for: .milliseconds(120))
        #expect(query.mutations.isEmpty)
    }
}
