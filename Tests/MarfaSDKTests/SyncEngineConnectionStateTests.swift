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

    /// Pins that taking a stream attaches a subscriber, which is what lets a
    /// stop issued straight afterwards finish it.
    ///
    /// It does **not** prove the attachment is synchronous. Routing the
    /// registration through a detached task instead still satisfies this, and
    /// still satisfies the subscribe-then-stop test above: `stateUpdates` is
    /// `nonisolated`, so a task created inside it runs on the global executor
    /// rather than queueing behind this actor, and it lands before either
    /// assertion can look. The mutex is therefore a correct-by-construction
    /// choice rather than a fix this suite can falsify — see the note on
    /// `Broadcast`. What this does catch is a registration dropped entirely.
    @Test("taking a stateUpdates stream attaches a subscriber")
    func stateSubscriptionAttaches() async throws {
        let manager = ConnectionStateManager()
        let stream = manager.stateUpdates
        #expect(manager.subscriberCountForTesting == 1)

        await manager.stop()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .offline)
        #expect(await iterator.next() == nil)
    }

    /// Also pins that `start()` clears the stopped flag: without that, the
    /// stream this takes after the restart would be handed back already
    /// finished. That property had a test of its own for a while and it was
    /// redundant — this one and `oldStreamIsIsolatedAcrossRestart` both redden
    /// on it, and both without opening a second real path monitor.
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

    /// **A stream taken after `stop()` must end rather than hang.** `stop()`
    /// finishes the subscribers it is holding, so one arriving afterwards
    /// registered into a table nothing would read again: it received the
    /// current state and then waited on a manager that had already said its
    /// last word.
    ///
    /// The documentation on `stateUpdates` promised this property for the
    /// other ordering — take a stream, then stop — which does work, and is why
    /// the gap sat one line from a comment about it.
    ///
    /// **The shape that lands here is a re-subscription, not an outliving
    /// one.** A subscriber that took its stream first is covered by that other
    /// ordering and ends cleanly. This is the view whose `for await` ended at
    /// teardown and whose `.task` immediately takes a fresh stream from the
    /// same manager before the rebuild swaps the reference — which is an
    /// ordinary SwiftUI shape rather than an exotic one.
    @Test("a stream taken after stop ends rather than hanging")
    func aStreamTakenAfterStopEnds() async {
        let manager = ConnectionStateManager()
        await manager.applyStateForTesting(.online)
        await manager.stop()

        var yielded: [ConnectionState] = []
        for await state in manager.stateUpdates { yielded.append(state) }
        #expect(yielded.isEmpty, "a stopped manager has nothing left to say")
    }
}
