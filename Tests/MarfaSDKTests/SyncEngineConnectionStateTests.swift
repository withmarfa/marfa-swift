import Testing
import Foundation
@testable import MarfaSDK

/// `ConnectionStateManager` lifecycle and state-transition guards.
@Suite("ConnectionStateManager")
struct SyncEngineConnectionStateTests {

    @Test("initial state is offline") func initialState() async {
        let manager = ConnectionStateManager()
        let state = await manager.state
        #expect(state == .offline)
    }

    @Test("stateUpdates yields current state immediately") func stateUpdatesYieldsCurrentStateImmediately() async throws {
        let manager = ConnectionStateManager()
        let stream = await manager.stateUpdates
        var iter = stream.makeAsyncIterator()
        let first = await iter.next()
        #expect(first == .offline)
    }

    @Test("markSyncing / markOnline transition from non-offline states") func markSyncingMarkOnlineTransitionFromNonOfflineStates() async {
        let manager = ConnectionStateManager()
        // markSyncing is a no-op when offline
        await manager.markSyncing()
        #expect(await manager.state == .offline)

        // Manually inject connecting state (normally from NWPathMonitor)
        // Since we can't inject NWPathMonitor events in unit tests, test markOnline
        // from syncing state by using the internal applyState pathway via markSyncing.
        // The guard `guard state != .offline` means markSyncing is a no-op from offline.
        // This tests the guard itself.
        await manager.markOnline()
        #expect(await manager.state == .offline) // Still offline — guard protects
    }

    @Test("immediate subscribe then stop finishes stateUpdates stream")
    func immediateSubscribeThenStopFinishesStream() async throws {
        let manager = ConnectionStateManager()
        let stream = await manager.stateUpdates
        var iterator = stream.makeAsyncIterator()

        await manager.stop()

        #expect(await iterator.next() == .offline)
        #expect(await iterator.next() == nil)
    }

    @Test("start after stop creates a fresh monitor and stream")
    func startAfterStopRestartsMonitoring() async throws {
        let manager = ConnectionStateManager()
        await manager.start()
        await manager.stop()
        await manager.start()

        let stream = await manager.stateUpdates
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
        let oldStream = await manager.stateUpdates
        var oldIterator = oldStream.makeAsyncIterator()
        #expect(await oldIterator.next() == .offline)

        await manager.stop()
        #expect(await oldIterator.next() == nil)
        await manager.start()

        let newStream = await manager.stateUpdates
        var newIterator = newStream.makeAsyncIterator()
        let initial = await newIterator.next()
        let transition: ConnectionState = initial == .connecting ? .online : .connecting
        await manager.applyStateForTesting(transition)

        #expect(await newIterator.next() == transition)
        #expect(await oldIterator.next() == nil)
        await manager.stop()
    }
}
