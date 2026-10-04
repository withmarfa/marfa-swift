import Foundation
import MarfaTypes
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct Cancellation {
    @Test(arguments: ["hydrate", "catchUp", "drain"])
    func anAlreadyCancelledTaskRefusesTheCall(operation: String) async throws {
        let core = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: false)
        let call: @Sendable () async throws -> Void = {
            switch operation {
            case "hydrate": _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
            case "catchUp": _ = try await copy.catchUp()
            default: _ = try await copy.queue.drain()
            }
        }
        try await call()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await call()
        }
        await #expect { try await task.value } throws: { error in
            if case MarfaError.canceled = error { true } else { false }
        }
        await copy.close()
    }

    @Test func anAlreadyCanceledCallOnAClosedCopyStillReportsClosed() async throws {
        let copy = WorkingCopy(holder: CoreHolder(FakeCore.writer()), hasServer: false)
        await copy.close()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await copy.queue.drain()
        }
        await #expect { try await task.value } throws: { error in
            if case MarfaError.closed = error { true } else { false }
        }
    }

    @Test func cancellationOfHydrationWithAnUnansweredPeerKeepsTheQueue() async throws {
        let server = try await LocalServer.start(contract: marfaContractVersion, holdsResponse: true)
        defer { server.stop() }
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: Server(url: server.url, key: "k"))
        try await copy.declareTypes([DeclaredTypes.definition])
        let queued = try await copy.items.create(Draft(type: "app.readinglist.entry", properties: ["title": "Kept"]))
        let task = Task { try await copy.hydrate(types: ["app.readinglist.entry"], tier: .library) }
        try await eventually("the peer received a request") { !server.log.all.isEmpty }
        task.cancel()
        await #expect {
            try await bounded("the canceled hydration", within: 55) { try await task.value }
        } throws: { error in
            if case MarfaError.canceled = error { true } else { false }
        }
        server.stop()
        #expect(try await copy.queue.all().contains { $0.id == queued.id && $0.verdict == nil })
        try await bounded("closing the canceled copy") { await copy.close() }
    }

}
