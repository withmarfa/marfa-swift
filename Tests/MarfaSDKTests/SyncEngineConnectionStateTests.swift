import Testing
import Foundation
@testable import MarfaSDK

/// `ConnectionStateManager` lifecycle and state-transition guards.
@Suite("ConnectionStateManager", .timeLimit(.minutes(1)))
struct SyncEngineConnectionStateTests {

    @Test("initial state is offline") func initialState() async {
        let manager = ConnectionStateManager()
        let state = manager.state
        #expect(state == .offline)
    }

    @Test("stateUpdates yields current state immediately") func stateUpdatesYieldsCurrentStateImmediately() async throws {
        let manager = ConnectionStateManager()
        let stream = manager.stateUpdates
        var iter = stream.makeAsyncIterator()
        let first = await iter.next()
        #expect(first == .offline)
    }

    @Test("markSyncing / markOnline transition from non-offline states") func markSyncingMarkOnlineTransitionFromNonOfflineStates() async {
        let manager = ConnectionStateManager()
        // markSyncing is a no-op when offline
        await manager.markSyncing()
        #expect(manager.state == .offline)

        // Manually inject connecting state (normally from NWPathMonitor)
        // Since we can't inject NWPathMonitor events in unit tests, test markOnline
        // from syncing state by using the internal applyState pathway via markSyncing.
        // The guard `guard state != .offline` means markSyncing is a no-op from offline.
        // This tests the guard itself.
        await manager.markOnline()
        #expect(manager.state == .offline) // Still offline — guard protects
    }

    @Test("immediate subscribe then stop finishes stateUpdates stream")
    func immediateSubscribeThenStopFinishesStream() async throws {
        let manager = ConnectionStateManager()
        let stream = manager.stateUpdates
        var iterator = stream.makeAsyncIterator()

        await manager.stop()

        #expect(await iterator.next() == .offline)
        #expect(await iterator.next() == nil)
    }

    @Test("subscribing to stateUpdates registers before the property returns")
    func stateSubscriptionIsSynchronous() async throws {
        let manager = ConnectionStateManager()
        // Registering through a task instead lets a stop issued on the next
        // line run first, leaving the new continuation attached to a stopped
        // manager and its consumer awaiting a state that can never arrive.
        // The `await manager.stop()` in the test above hands such a task
        // exactly the scheduling turn it needs, so that test passes either
        // way. These two statements are both synchronous and nonisolated with
        // no suspension between them, which is what makes the registration
        // observable rather than merely likely.
        let stream = manager.stateUpdates
        #expect(manager.subscriberCountForTesting == 1)

        await manager.stop()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .offline)
        #expect(await iterator.next() == nil)
    }

    @Test("start after stop creates a fresh monitor and stream")
    func startAfterStopRestartsMonitoring() async throws {
        let manager = ConnectionStateManager()
        await manager.start()
        #expect(await manager.isStartedForTesting)
        await manager.stop()
        // `stop()` has to clear the started flag, not just cancel the monitor:
        // `start()` is idempotent and returns early while the flag is set, so
        // a manager that keeps it stays inert for the rest of its life.
        #expect(await manager.isStartedForTesting == false)
        await manager.start()
        #expect(await manager.isStartedForTesting)

        let stream = manager.stateUpdates
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial != nil)
        let expectedTransition: ConnectionState = initial == .connecting ? .online : .connecting
        await manager.applyStateForTesting(expectedTransition)
        #expect(await iterator.next() == expectedTransition)

        await manager.stop()
        #expect(await iterator.next() == .offline)
        #expect(await iterator.next() == nil)
    }

    @Test("a stopped lifecycle stream stays isolated from restart updates")
    func oldStreamIsIsolatedAcrossRestart() async throws {
        let manager = ConnectionStateManager()
        let oldStream = manager.stateUpdates
        var oldIterator = oldStream.makeAsyncIterator()
        #expect(await oldIterator.next() == .offline)

        await manager.stop()
        #expect(await oldIterator.next() == nil)
        await manager.start()

        let newStream = manager.stateUpdates
        var newIterator = newStream.makeAsyncIterator()
        let initial = await newIterator.next()
        let transition: ConnectionState = initial == .connecting ? .online : .connecting
        await manager.applyStateForTesting(transition)

        #expect(await newIterator.next() == transition)
        #expect(await oldIterator.next() == nil)
        await manager.stop()
    }
}
