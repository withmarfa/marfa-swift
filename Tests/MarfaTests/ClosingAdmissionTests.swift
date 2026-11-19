import Dispatch
import Foundation
import MarfaCore
import Synchronization
import Testing

@testable import Marfa

private func isClosed(_ error: any Error) -> Bool {
    if case Marfa.MarfaError.closed = error { true } else { false }
}

/// Whether a read or a write started now is refused as closed; any other failure is thrown.
private func refusesNewCalls(_ copy: WorkingCopy) async throws -> Bool {
    do {
        _ = try await copy.status()
        return false
    } catch {
        guard isClosed(error) else { throw error }
    }
    do {
        try await copy.declareTypes([])
        return false
    } catch {
        guard isClosed(error) else { throw error }
    }
    return true
}

@Suite(.timeLimit(.minutes(1)))
struct AClosingCopy {
    @Test func refusesNewReadsAndWritesWhileItsWatchIsStillEnding() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let gate = core.holdNextWatch()
        defer { gate.signal() }
        let stream = Task.detached { copy.changes() }
        try await eventually("the watch call is held") { core.aWatchWasHeld }

        let closed = Mutex(false)
        let closing = Task {
            await copy.close()
            closed.withLock { $0 = true }
        }
        try await eventually("new reads and writes are refused", within: 5) { try await refusesNewCalls(copy) }
        #expect(!closed.withLock { $0 }, "close returned while the watch was still held")

        gate.signal()
        try await bounded("close") { await closing.value }
        _ = await stream.value
    }

    @Test func refusesNewCallsWhileAnAdmittedOneFinishesAndEveryCloserWaitsForIt() async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let gate = core.holdNextRead()
        defer { gate.signal() }
        let admitted = Task { try await copy.holder.run { try $0.dataVersion() } }
        try await eventually("the call is held") { core.aReadWasHeld }

        let closed = Mutex(0)
        let closers = (0..<2).map { _ in
            Task {
                await copy.close()
                closed.withLock { $0 += 1 }
            }
        }
        try await eventually("new reads and writes are refused", within: 5) { try await refusesNewCalls(copy) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(closed.withLock { $0 } == 0, "a close returned while a call it admitted was running")

        core.save()
        gate.signal()
        #expect(
            try await bounded("the admitted call") { try await admitted.value } == 1, "the admitted call did not finish"
        )
        for closer in closers { try await bounded("close") { await closer.value } }
        #expect(closed.withLock { $0 } == 2)
        #expect(copy.holder.isClosed)
    }

    @Test func releasesTheStoreSoTheNextOpenerWritesWhileAStreamIsHeld() async throws {
        let store = temporaryStore()
        let first = try await WorkingCopy.open(store: store)
        #expect(first.handle == .writer)
        let stream = Task.detached { Heard(first.changes()) }
        let racing = Task { try? await first.status() }
        try await bounded("close") { await first.close() }
        _ = await racing.value
        _ = await stream.value

        let second = try await WorkingCopy.open(store: store)
        #expect(second.handle == .writer, "the closed copy still held the store")
        await second.close()
    }
}
