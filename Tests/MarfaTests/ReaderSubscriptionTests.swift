import Foundation
import MarfaCore
import Synchronization
import Testing

@testable import Marfa

/// A reader's place in the watch is taken off the thread that asks for it, since the core reads the store's data
/// version there, and the store's one connection is held by any call running on the copy.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct ASubscribingReader {
    @Test func aLiveQueryIsCreatedAtOnceWhileTheReaderIsBusy() async throws {
        let core = FakeCore.reader()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let gate = core.holdNextWatch()
        // A blocked initializer ends the test after two seconds instead of hanging it.
        let timer = Task.detached {
            try? await Task.sleep(for: .seconds(2))
            gate.signal()
        }
        defer {
            timer.cancel()
            gate.signal()
        }
        let seen = Mutex<Int?>(nil)
        let reading = Reading<String>(placeholder: "none") { _ in
            seen.withLock { if $0 == nil { $0 = core.places.count } }
            return "read"
        }

        let start = ContinuousClock.now
        let query = LiveQuery(copy, reading: reading)
        let took = ContinuousClock.now - start
        #expect(took < .milliseconds(500), "the initializer waited \(took) on the reader's watch")

        try await eventually("the watch call is held") { core.aWatchWasHeld }
        try await Task.sleep(for: .milliseconds(200))
        #expect(seen.withLock { $0 } == nil, "the first read began before the reader had its place in the watch")
        gate.signal()
        try await eventually("the first read ended") { !query.isLoading }
        #expect(seen.withLock { $0 } == 1, "the first read began before the reader had its place in the watch")
        await copy.close()
    }

    @Test func aSaveWhileTheStreamTakesItsPlaceIsTold() async throws {
        let core = FakeCore.reader()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let gate = core.holdNextWatch()
        defer { gate.signal() }
        let heard = Task.detached { Heard(copy.changes()) }
        try await eventually("the watch call is held") { core.aWatchWasHeld }

        core.save()
        gate.signal()
        let changes = await heard.value
        try await eventually("the save was told", within: 5) {
            changes.saves.contains { $0.change.origin == .saved(dataVersion: 1) }
        }
        await copy.close()
    }

    @Test func aSaveWhileALiveQueryTakesItsPlaceIsInItsFirstRead() async throws {
        let core = FakeCore.reader()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let gate = core.holdNextWatch()
        defer { gate.signal() }
        let reading = Reading<Int64>(placeholder: -1) { copy in
            try await copy.holder.run { try $0.dataVersion() }
        }
        let query = LiveQuery(copy, reading: reading)
        try await eventually("the watch call is held") { core.aWatchWasHeld }

        core.save()
        gate.signal()
        try await eventually("the first read ended") { !query.isLoading }
        #expect(query.value == 1, "the first read began before the save, and nothing told the query of it")
        await copy.close()
    }
}
