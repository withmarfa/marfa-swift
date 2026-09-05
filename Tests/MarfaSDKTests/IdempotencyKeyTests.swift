import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// Every queued write carries the same `Idempotency-Key` on every attempt.
///
/// **The property is sameness, not presence.** A key that changed per attempt
/// would look identical in a request log and protect nothing — it would tell
/// the server each retry was a new request. So these tests assert that two
/// attempts at one row carry one value, and that two different rows do not
/// share one.
@Suite("Every write carries a key, and a retry carries the same one", .timeLimit(.minutes(1)))
struct IdempotencyKeyTests {

    private func echo(_ id: String) -> ItemResponse {
        let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        return ItemResponse(
            item: Item(
                createdAt: now, id: id, properties: ["body": .string("x")],
                schemaVersion: 1, source: "test", state: .active, tier: .library,
                timestamp: now, type: "core.note", updatedAt: now, version: 1
            ),
            metadata: nil
        )
    }

    /// The POST /items attempts the transport actually saw.
    private func creates(_ transport: MockTransport) -> [MockTransport.Call] {
        transport.calls.filter { $0.path == "/items" && $0.method == .post }
    }

    /// A started engine drains on its own whenever the queue signals, so a
    /// test waits for the attempts it expects rather than calling replay once
    /// and assuming that was the only cycle. Racing an explicit replay against
    /// the proactive one is how the first version of this suite read one
    /// attempt where two had happened.
    /// The discriminator for the whole feature: a replay whose first response
    /// was lost sends the key again, unchanged, so the server can recognize
    /// the write it already performed instead of doing it twice.
    @Test("a retry after a lost response repeats the key rather than minting one")
    func retryRepeatsTheKey() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueueEvents([])
        await engine.start()
        defer { Task { await engine.stop() } }

        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        let item = try await store.createItem(input)
        try await queue.enqueueCreateItem(input, localId: item.id)

        // A lost response: the write reached the server, the acknowledgement
        // did not. From here that is indistinguishable from never arriving,
        // which is exactly why the key has to survive it.
        transport.enqueueError(NetworkError(URLError(.timedOut)))
        transport.enqueue(echo(item.id))
        await engine.replayMutationsForTesting()
        try await SyncEngineTestKit.awaitCondition(description: "two create attempts") {
            self.creates(transport).count >= 2
        }

        let writes = creates(transport)
        try #require(writes.count == 2)
        let keys = writes.map(\.idempotencyKey)
        #expect(keys.allSatisfy { $0 != nil }, "both attempts must carry a key")
        #expect(keys[0] == keys[1], "a retry is the same request, so it is the same key")
    }

    /// The other half, and the reason the test above is not satisfied by a
    /// constant: two distinct writes must not share a key, or the server would
    /// treat the second as a replay of the first and silently drop it.
    @Test("two different writes carry different keys")
    func distinctWritesGetDistinctKeys() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueueEvents([])
        await engine.start()
        defer { Task { await engine.stop() } }

        for body in ["one", "two"] {
            let input = CreateItemInput(type: "core.note", properties: ["body": .string(body)])
            let item = try await store.createItem(input)
            try await queue.enqueueCreateItem(input, localId: item.id)
            transport.enqueue(echo(item.id))
        }
        await engine.replayMutationsForTesting()
        try await SyncEngineTestKit.awaitCondition(description: "both creates attempted") {
            self.creates(transport).count >= 2
        }

        let keys = creates(transport).compactMap(\.idempotencyKey)
        try #require(keys.count == 2)
        #expect(Set(keys).count == 2)
    }

    /// A key is minted by the one private door every kind funnels through, so
    /// this holds for a write that is not a create — which is the half the
    /// client-minted item id never covered.
    @Test("a write that is not a create carries a key too")
    func nonCreateWritesCarryAKey() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueueEvents([])
        await engine.start()
        defer { Task { await engine.stop() } }

        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        let item = try await store.createItem(input)
        try await queue.enqueueSetMetadata(itemId: item.id, input: MetadataInput(tags: ["a"]))

        transport.enqueue(MetadataResponse(metadata: Metadata(extensions: [:], itemId: item.id, tags: ["a"])))
        await engine.replayMutationsForTesting()
        try await SyncEngineTestKit.awaitCondition(description: "the metadata write was attempted") {
            transport.calls.contains { $0.method == .put || $0.method == .post }
        }

        let write = transport.calls.first { $0.method == .put || $0.method == .post }
        #expect(write?.idempotencyKey != nil)
    }

    /// A row enqueued before keys existed replays **without** one rather than
    /// being given a fresh one. A key invented at replay time differs on every
    /// attempt, which is worse than none: it would tell the server each retry
    /// was a new request while looking, from here, like protection.
    @Test("a row with no key replays without one rather than inventing one")
    func rowWithoutAKeyIsNotGivenOne() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueueEvents([])
        await engine.start()
        defer { Task { await engine.stop() } }

        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        let item = try await store.createItem(input)
        try await queue.enqueueCreateItem(input, localId: item.id)
        try await queue.clearIdempotencyKeyForTesting(localId: item.id)

        transport.enqueueError(NetworkError(URLError(.timedOut)))
        transport.enqueue(echo(item.id))
        await engine.replayMutationsForTesting()
        try await SyncEngineTestKit.awaitCondition(description: "two create attempts") {
            self.creates(transport).count >= 2
        }

        let writes = creates(transport)
        try #require(writes.count == 2)
        #expect(writes.allSatisfy { $0.idempotencyKey == nil })
    }
}
