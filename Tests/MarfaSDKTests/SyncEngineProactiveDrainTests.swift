import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// Proactive drain on enqueue — when a mutation is enqueued while the engine
/// is online, a debounced drain cycle replays the queue without waiting for
/// the next network transition. Burst enqueues collapse to a single cycle
/// via the debouncer. Offline / syncing states are no-ops (avoid racing an
/// in-flight drain).
///
/// Uses ``SyncEngineTestKit.makeFixtureWithShortDebounce`` so the 20 ms
/// debounce keeps assertions tight without sleeping for the 150 ms default.
@Suite("SyncEngine proactive drain", .timeLimit(.minutes(1)))
struct SyncEngineProactiveDrainTests {

    @Test("proactive drain fires when a mutation is enqueued while online")
    func proactiveDrainFiresWhenOnline() async throws {
        let (_, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixtureWithShortDebounce()

        // Engine consumes an empty SSE stream, marks .online, then idles
        // until a drain request wakes it.
        transport.enqueueEvents([])
        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        // Wait until the stream close has landed us on .online.
        try await SyncEngineTestKit.waitUntil(timeout: .milliseconds(500)) {
            await connManager.state == .online
        }

        // Queue a delete. Transport replies with a 204 via EmptyResponse
        // envelope — mock returns any successful decoded shape.
        transport.enqueue(EmptyResponse())
        try await queue.enqueueDeleteItem(id: "server-x")

        // Debounce (20 ms) + replay should clear the queue promptly.
        try await SyncEngineTestKit.waitUntil(timeout: .milliseconds(500)) {
            (try? await queue.isEmpty) == true
        }
        #expect(try await queue.isEmpty)
        await engine.stop()
    }

    @Test("burst enqueues collapse to a single drain cycle")
    func burstEnqueuesCollapseToSingleDrain() async throws {
        let (_, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixtureWithShortDebounce()

        transport.enqueueEvents([])
        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        try await SyncEngineTestKit.waitUntil(timeout: .milliseconds(500)) {
            await connManager.state == .online
        }

        // Five mutations back-to-back. Each expects one transport round
        // trip. If the debouncer works, all fire on a single replay
        // cycle rather than triggering five separate cycles.
        for _ in 0..<5 {
            transport.enqueue(EmptyResponse())
        }
        for i in 0..<5 {
            try await queue.enqueueDeleteItem(id: "burst-\(i)")
        }

        try await SyncEngineTestKit.waitUntil(timeout: .milliseconds(500)) {
            (try? await queue.isEmpty) == true
        }

        // Five delete calls landed on the transport — one replay burst
        // covering the whole queue snapshot, not five separate cycles.
        let deletes = transport.calls.filter {
            $0.method == .delete && $0.path.hasPrefix("/items/burst-")
        }
        #expect(deletes.count == 5)
        await engine.stop()
    }

    @Test("proactive drain is a no-op when offline")
    func proactiveDrainNoOpOffline() async throws {
        // Exercise the gate directly via the test hook — `NWPathMonitor`
        // races with `applyStateForTesting` on networked dev machines,
        // which would otherwise transition the engine to `.connecting`
        // and drain the queue via the SSE-close path before the assert.
        let (_, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixtureWithShortDebounce()

        await connManager.applyStateForTesting(.offline)
        try await queue.enqueueDeleteItem(id: "never")

        await engine.triggerProactiveDrainForTesting()

        #expect(try await queue.isEmpty == false)
        let deletes = transport.calls.filter {
            $0.method == .delete && $0.path == "/items/never"
        }
        #expect(deletes.isEmpty)
    }

    @Test("proactive drain is a no-op when syncing")
    func proactiveDrainNoOpSyncing() async throws {
        // `.syncing` means a drain is already in flight. A second
        // concurrent drain would race over the same records.
        let (_, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixtureWithShortDebounce()

        await connManager.applyStateForTesting(.syncing)
        try await queue.enqueueDeleteItem(id: "never")

        await engine.triggerProactiveDrainForTesting()

        #expect(try await queue.isEmpty == false)
        let deletes = transport.calls.filter {
            $0.method == .delete && $0.path == "/items/never"
        }
        #expect(deletes.isEmpty)
    }
}
