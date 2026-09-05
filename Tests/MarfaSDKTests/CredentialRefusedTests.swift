import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// **A refusal the queue used to retry for ever.**
///
/// The contract's failure table puts a `401` — one the transport's single
/// refresh did not clear — in a class of its own: park the whole queue, say so,
/// and drop nothing. The kit classed it environmental instead, alongside a
/// `5xx` and a dropped connection, on the reasoning that everything in that
/// class clears without the app doing anything.
///
/// That reasoning holds for a network and does not hold for a credential. A
/// revoked key answers `401` for ever, so the queue spun, and an app could show
/// only a count of unsent writes that never moved — with nothing anywhere
/// saying that a person had to sign in again.
@Suite("A refused credential parks the queue", .timeLimit(.minutes(1)))
struct CredentialRefusedTests {

    private func queueThree(_ queue: MutationQueue) async throws {
        for label in ["one", "two", "three"] {
            var input = CreateItemInput(type: "core.note", properties: ["body": .string(label)])
            input.id = UUIDv7.generateString()
            try await queue.enqueueCreateItem(input, localId: input.id!)
        }
    }

    @Test("a 401 parks every queued write rather than retrying it")
    func aRefusedCredentialParksTheWholeQueue() async throws {
        let (_, queue, transport, manager, engine) = try await SyncEngineTestKit.makeFixture()
        try await queueThree(queue)

        // One refusal, not three: the first row's answer settles the rest.
        transport.enqueueError(UnauthorizedError(message: "key revoked"))

        await manager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        let counts = try await queue.counts
        #expect(counts.pending == 0, "nothing is still waiting to be tried")
        #expect(counts.inFlight == 0)
        #expect(
            counts.blocked[.credentialRefused] == 3,
            "all three park together: \(counts.blocked)"
        )
        #expect(counts.deadLettered == 0, "parked, not dropped")

        // And only one request was spent learning it.
        let writes = transport.calls.filter { $0.method == .post && $0.path == "/items" }
        #expect(writes.count == 1, "sent \(writes.count) writes to learn one answer")
    }

    @Test("the parking is announced, with how many it took")
    func theParkingIsAnnounced() async throws {
        let (_, queue, transport, manager, engine) = try await SyncEngineTestKit.makeFixture()
        try await queueThree(queue)
        transport.enqueueError(UnauthorizedError(message: "key revoked"))

        let events = engine.events
        let seen = ParkBox()
        let watcher = Task {
            for await event in events {
                if case .queueParked(let reason, let count) = event {
                    await seen.add(reason: reason, count: count)
                }
            }
        }
        defer { watcher.cancel() }

        await manager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        try await SyncEngineTestKit.awaitCondition(description: "a queueParked event") {
            await seen.parks.count >= 1
        }
        let parks = await seen.parks
        #expect(parks.count == 1, "one announcement per parking, not one per row")
        #expect(parks.first?.reason == .credentialRefused)
        #expect(parks.first?.count == 3, "the count is every write parked, not the rest")
    }

    @Test("a refusal about the credential does not spend the retry ceiling")
    func itParksOnTheFirstRefusalRatherThanTheFifth() async throws {
        let (_, queue, transport, manager, engine) = try await SyncEngineTestKit.makeFixture()
        var input = CreateItemInput(type: "core.note", properties: ["body": .string("only")])
        input.id = UUIDv7.generateString()
        try await queue.enqueueCreateItem(input, localId: input.id!)

        transport.enqueueError(UnauthorizedError(message: "key revoked"))
        await manager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        let row = try #require(try await queue.fetchAll().first)
        #expect(row.state == .blocked)
        #expect(row.blockedReason == .credentialRefused, "not retries exhausted, which names the wrong cause")
        #expect(row.refusalCount == 0, "the ceiling is for refusals of the write, not of the key")
    }

    /// **Release by reason, because a new credential settles nothing else.** A
    /// conflict awaiting review is not resolved by signing in again, and
    /// sweeping it up would tell an app it was moving when nothing had changed
    /// for it.
    @Test("releasing the credential class leaves other parked work alone")
    func releasingOneReasonLeavesTheOthers() async throws {
        let (_, queue, transport, manager, engine) = try await SyncEngineTestKit.makeFixture()
        try await queueThree(queue)

        let rows = try await queue.fetchAll()
        try await queue.recordBlocked(
            id: rows[2].id,
            reason: PendingMutationBlockReason.conflictUnresolved,
            error: "somebody has to settle this"
        )

        transport.enqueueError(UnauthorizedError(message: "key revoked"))
        await manager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        let parked = try await queue.counts
        #expect(parked.blocked[.credentialRefused] == 2)
        #expect(parked.blocked[.conflictUnresolved] == 1, "the conflict keeps its own reason")

        let released = try await engine.retryAll(reason: .credentialRefused)
        #expect(released == 2)

        let after = try await queue.counts
        #expect(after.pending == 2, "the two on the credential are sendable again")
        #expect(after.blocked[.credentialRefused] == nil)
        #expect(after.blocked[.conflictUnresolved] == 1, "still waiting for a person")
    }

    /// A key answered for a different body cannot be replayed into a different
    /// answer, so repeating it four more times is four guaranteed refusals and
    /// then a reason naming the wrong cause.
    @Test("a spent idempotency key parks on the first refusal")
    func aSpentKeyParksImmediately() async throws {
        let (_, queue, transport, manager, engine) = try await SyncEngineTestKit.makeFixture()
        var input = CreateItemInput(type: "core.note", properties: ["body": .string("only")])
        input.id = UUIDv7.generateString()
        try await queue.enqueueCreateItem(input, localId: input.id!)

        transport.enqueueError(MarfaError(
            code: MarfaError.idempotencyKeyReusedCode,
            message: "that key already answered a different body",
            status: 422
        ))
        await manager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        let row = try #require(try await queue.fetchAll().first)
        #expect(row.blockedReason == .idempotencyKeyReused)
        #expect(row.refusalCount == 0, "the ceiling is not spent on a refusal that cannot change")

        let writes = transport.calls.filter { $0.method == .post && $0.path == "/items" }
        #expect(writes.count == 1, "sent \(writes.count) times; the key is spent, not the write")
    }

    /// The environmental class is unchanged for everything that really does
    /// clear on its own, which is what stops this fix stranding a valid write
    /// behind an outage.
    @Test("a 500 and a suspended space still ride it out")
    func theEnvironmentalClassIsUnchanged() async throws {
        #expect(
            PendingMutationBlockReason.classify(
                error: MarfaError(code: "server_error", message: "boom", status: 500),
                kind: .createItem, refusalCount: 0, ceiling: 5
            ) == nil
        )
        #expect(
            PendingMutationBlockReason.classify(
                error: MarfaError(
                    code: MarfaError.spaceSuspendedCode, message: "paused", status: 403
                ),
                kind: .createItem, refusalCount: 0, ceiling: 5
            ) == nil
        )
        #expect(
            PendingMutationBlockReason.classify(
                error: NetworkError(URLError(.notConnectedToInternet)),
                kind: .createItem, refusalCount: 0, ceiling: 5
            ) == nil
        )
    }
}

private actor ParkBox {
    private(set) var parks: [(reason: PendingMutationBlockReason, count: Int)] = []
    func add(reason: PendingMutationBlockReason, count: Int) { parks.append((reason, count)) }
}
