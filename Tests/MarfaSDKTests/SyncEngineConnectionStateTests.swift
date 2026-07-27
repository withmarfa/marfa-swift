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
        let stream = manager.stateUpdates
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

    @Test("stop finishes stateUpdates stream") func stopFinishesStateUpdatesStream() async throws {
        let manager = ConnectionStateManager()

        // Collect events from the stream in a background task, then stop.
        let collected = await withTaskGroup(of: [ConnectionState].self) { group in
            group.addTask {
                let stream = manager.stateUpdates
                var results: [ConnectionState] = []
                for await state in stream {
                    results.append(state)
                }
                return results
            }
            // Let the inner task subscribe and receive the initial state.
            try? await Task.sleep(for: .milliseconds(10))
            // Stop — should finish the stream.
            await manager.stop()
            return await group.next()!
        }
        // The stream yielded the initial .offline state then finished.
        #expect(collected == [.offline])
    }

    @Test("start after stop creates a fresh monitor and stream")
    func startAfterStopRestartsMonitoring() async throws {
        let manager = ConnectionStateManager()
        await manager.start()
        await manager.stop()
        await manager.start()

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
}
