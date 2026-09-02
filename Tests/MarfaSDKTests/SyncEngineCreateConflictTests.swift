import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// The acknowledgement body `POST /items` answers a repeated create with.
///
/// `ItemResponse` is what the SDK decodes and carries no `acknowledged`
/// field, so a test enqueueing one could not tell the two apart on the wire.
/// This is the body as the route actually writes it, which is what the engine
/// has to behave correctly against.
private struct AcknowledgedItemBody: Encodable {
    let item: Item
    let metadata: Metadata
    let acknowledged: Bool
}

/// A create that meets a conflict is refused for good, and one the server
/// acknowledges is adopted.
///
/// Both halves are the same defect seen from opposite ends: a synced client
/// names its own rows, so a create retried after a lost response is a repeat
/// rather than a collision, and the two answers a server can give it —  the
/// row itself, or a refusal naming somebody else's row — are both final.
@Suite("A create meeting a conflict", .timeLimit(.minutes(1)))
struct SyncEngineCreateConflictTests {

    // MARK: - Fixtures

    private static let stamped = "2026-09-02T00:00:00.000Z"

    private func serverItem(id: String, version: Int, body: String) -> Item {
        // `version` is stamped by the server and unknowable to the local mint,
        // so a version on the local row that the device never wrote proves the
        // row came from the response. `spaceId` would say the same but cannot
        // be asserted: the store holds one space's rows and has no column for
        // it, so it does not survive the round trip.
        Item(
            createdAt: Self.stamped,
            id: id,
            properties: ["body": .string(body)],
            schemaVersion: 1,
            source: "server",
            state: .active,
            tier: .feed,
            timestamp: Self.stamped,
            type: "core.note",
            updatedAt: Self.stamped,
            version: version
        )
    }

    /// The refusal a create meets when the id names a row this caller cannot
    /// see. Built the way the transport builds it from the wire, so the code
    /// under assertion is the server's own rather than one the test invented.
    private func conflict(code: String, message: String) -> MarfaError {
        let body = #"{"error":{"code":"\#(code)","message":"\#(message)"}}"#
        return parseMarfaError(data: Data(body.utf8), statusCode: 409)
    }

    // MARK: - The acknowledged repeat

    @Test("a create the server acknowledges leaves one adopted item, an empty queue and no drop")
    func acknowledgedRepeatIsAdopted() async throws {
        let (store, queue, transport, connManager, engine) =
            try await SyncEngineTestKit.makeFixture()
        await engine.setReconnectDelaysForTesting(base: 0.01, max: 0.05)

        let id = UUIDv7.generateString()
        let local = serverItem(id: id, version: 1, body: "v1")
        try await store.upsertItem(local)
        try await queue.enqueueCreateItem(
            CreateItemInput(type: "core.note", properties: ["body": .string("v1")], id: id),
            localId: id
        )

        // The lost-response case: the server already holds this row, so it
        // writes nothing and hands back what it has — which has moved on from
        // what this device wrote.
        transport.enqueueEvents([])
        transport.enqueue(AcknowledgedItemBody(
            item: serverItem(id: id, version: 7, body: "what the server holds"),
            metadata: Metadata(extensions: [:], itemId: id, tags: ["from-the-server"]),
            acknowledged: true
        ))

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.waitUntil(
            timeout: .milliseconds(500),
            description: "(try? await queue.isEmpty) == true"
        ) {
            (try? await queue.isEmpty) == true
        }

        // One item, and it is the server's copy rather than the local mint.
        let stored = try await store.fetchItem(id: id)
        #expect(stored.version == 7)
        #expect(stored.properties["body"] == .string("what the server holds"))
        #expect(try await store.fetchMetadata(itemId: id).tags == ["from-the-server"])

        // Adopted, not dead-lettered.
        #expect(try await queue.fetchDropped().isEmpty)

        await engine.stop()
    }

    // MARK: - The refusal

    @Test("a conflict on a create is dropped once with the server's code, and never retried")
    func createConflictIsDroppedOnce() async throws {
        let (store, queue, transport, connManager, engine) =
            try await SyncEngineTestKit.makeFixture()
        await engine.setReconnectDelaysForTesting(base: 0.01, max: 0.05)

        let id = UUIDv7.generateString()
        try await store.upsertItem(serverItem(id: id, version: 1, body: "mine"))
        try await queue.enqueueCreateItem(
            CreateItemInput(type: "core.note", properties: ["body": .string("mine")], id: id),
            localId: id
        )

        let events = await engine.events
        let collector = Task { () -> [SyncEvent] in
            var out: [SyncEvent] = []
            for await event in events {
                out.append(event)
                if case .mutationDropped = event { return out }
                if case .synced = event { return out }
            }
            return out
        }

        transport.enqueueEvents([])
        transport.enqueueError(
            conflict(code: "conflict", message: "Item with id=\(id) already exists")
        )

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.waitUntil(
            timeout: .milliseconds(500),
            description: "(try? await queue.isEmpty) == true"
        ) {
            (try? await queue.isEmpty) == true
        }

        // Dead-lettered with what the server said, so an app can explain it.
        let dropped = try await queue.fetchDropped()
        #expect(dropped.count == 1)
        let entry = try #require(dropped.first)
        #expect(entry.kind == .createItem)
        #expect(entry.localId == id)
        #expect(entry.errorStatus == 409)
        #expect(entry.errorCode == "conflict")

        let collected = await collector.value
        let drop = collected.first { if case .mutationDropped = $0 { return true } else { return false } }
        #expect(drop != nil)
        if case let .mutationDropped(kind, itemId, attempt, error) = drop {
            #expect(kind == "createItem")
            #expect(itemId == id)
            #expect(attempt == 1)
            #expect(error.status == 409)
        }

        // And it is gone rather than merely quiet: a second drain has nothing
        // to send, which is the half a passing queue-empty assertion alone
        // would not distinguish from a record waiting for the next cycle.
        let callsAfterDrop = transport.calls.filter { $0.path == "/items" }.count
        await engine.replayMutationsForTesting()
        #expect(transport.calls.filter { $0.path == "/items" }.count == callsAfterDrop)

        await engine.stop()
    }

    @Test("a conflict on a create takes its dependents and its local row with it")
    func createConflictCascades() async throws {
        let (store, queue, transport, connManager, engine) =
            try await SyncEngineTestKit.makeFixture()
        await engine.setReconnectDelaysForTesting(base: 0.01, max: 0.05)

        let id = UUIDv7.generateString()
        try await store.upsertItem(serverItem(id: id, version: 1, body: ""))
        try await queue.enqueueCreateItem(
            CreateItemInput(type: "core.note", properties: ["body": .string("")], id: id),
            localId: id
        )
        // The edit queued behind the refused create. It can only ever 404.
        try await queue.enqueueUpdateItem(id: id, properties: ["body": .string("typed")])

        let events = await engine.events
        let collector = Task { () -> [SyncEvent] in
            var out: [SyncEvent] = []
            for await event in events {
                out.append(event)
                if case .synced = event { return out }
                if case .failed = event { return out }
            }
            return out
        }

        transport.enqueueEvents([])
        transport.enqueueError(
            conflict(code: "type_mismatch", message: "Item \(id) is not a core.note")
        )

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.waitUntil(
            timeout: .milliseconds(500),
            description: "(try? await queue.isEmpty) == true"
        ) {
            (try? await queue.isEmpty) == true
        }

        // The ghost is gone — an app stops showing a row that can never sync.
        #expect((try? await store.fetchItem(id: id)) == nil)

        let collected = await collector.value
        let dropped = collected.compactMap { event -> String? in
            if case let .mutationDropped(kind, _, _, _) = event { return kind }
            return nil
        }
        #expect(Set(dropped) == Set(["createItem", "updateItem"]))
        #expect(try await queue.fetchDropped().count == 2)

        await engine.stop()
    }

    @Test("a conflict on an edge create is dropped with its code and the local edge removed")
    func edgeCreateConflictIsDropped() async throws {
        let (store, queue, transport, connManager, engine) =
            try await SyncEngineTestKit.makeFixture()
        await engine.setReconnectDelaysForTesting(base: 0.01, max: 0.05)

        let edgeId = UUIDv7.generateString()
        try await store.upsertEdge(Edge(
            createdAt: Self.stamped,
            edgeType: "in-thread",
            id: edgeId,
            properties: [:],
            sourceId: "A",
            spaceId: nil,
            targetId: "B",
            updatedAt: Self.stamped
        ))
        try await queue.enqueueCreateEdge(
            source: "A", target: "B", edgeType: "in-thread",
            properties: nil, localEdgeId: edgeId
        )

        transport.enqueueEvents([])
        transport.enqueueError(
            conflict(code: "conflict", message: "Edge with id=\(edgeId) already exists")
        )

        await engine.start()
        await connManager.applyStateForTesting(.connecting)

        try await SyncEngineTestKit.waitUntil(
            timeout: .milliseconds(500),
            description: "(try? await queue.isEmpty) == true"
        ) {
            (try? await queue.isEmpty) == true
        }

        let dropped = try await queue.fetchDropped()
        #expect(dropped.count == 1)
        let entry = try #require(dropped.first)
        #expect(entry.kind == .createEdge)
        #expect(entry.errorStatus == 409)
        #expect(entry.errorCode == "conflict")

        // The local edge is gone: it names a row the server holds for
        // somebody else, so nothing on this device can ever reconcile it.
        #expect((try? await store.fetchEdge(id: edgeId)) == nil)

        await engine.stop()
    }
}
