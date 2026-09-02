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

/// A store that refuses to hold what the engine hands it, so the adoption's
/// failure path is reachable. Only item upserts fail; everything else is a
/// no-op, which keeps the refusal the single variable in a test.
private actor RefusingLocalStore: LocalStoreWriting {
    func upsertItem(_ item: Item) throws {
        throw LocalStoreError.encodingFailure("upsertItem(\(item.id))")
    }
    func upsertEdge(_ edge: Edge) throws {}
    func deleteEdge(id: String) throws {}
    func upsertMetadata(_ metadata: Metadata) throws {}
    func purgeItem(id: String) throws {}
}

/// A create that meets a conflict is refused for good, and one the server
/// acknowledges is adopted.
///
/// Both halves are the same defect seen from opposite ends: a synced client
/// names its own rows, so a create retried after a lost response is a repeat
/// rather than a collision, and the two answers a server can give it — the
/// row itself, or a refusal naming somebody else's row — are both final.
///
/// Every test here drives the drain through `triggerProactiveDrainForTesting`,
/// which awaits the replay to completion. Nothing waits on a deadline, so a
/// failure is an expectation about the queue rather than a timeout that could
/// equally mean a busy machine.
@Suite("A create meeting a conflict", .timeLimit(.minutes(1)))
struct SyncEngineCreateConflictTests {

    private static let stamped = "2026-09-02T00:00:00.000Z"

    /// `version` is stamped by the server and unknowable to the local mint, so
    /// a version on the local row the device never wrote proves the row came
    /// from the response. `spaceId` would say the same but cannot be asserted:
    /// the store holds one space's rows and has no column for it.
    private func serverItem(id: String, version: Int, body: String) -> Item {
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

    private func localEdge(id: String, source: String, target: String) -> Edge {
        Edge(
            createdAt: Self.stamped,
            edgeType: "in-thread",
            id: id,
            properties: [:],
            sourceId: source,
            spaceId: nil,
            targetId: target,
            updatedAt: Self.stamped
        )
    }

    /// A refusal built the way the transport builds one from the wire, so the
    /// code under assertion is the server's own rather than one a test
    /// invented for itself.
    private func serverError(status: Int, code: String, message: String) -> MarfaError {
        let body = #"{"error":{"code":"\#(code)","message":"\#(message)"}}"#
        return parseMarfaError(data: Data(body.utf8), statusCode: status)
    }

    // MARK: - The acknowledged repeat

    @Test("a create the server acknowledges leaves one adopted item, an empty queue and no drop")
    func acknowledgedRepeatIsAdopted() async throws {
        let (store, queue, transport, connManager, engine) =
            try await SyncEngineTestKit.makeFixture()

        let id = UUIDv7.generateString()
        try await store.upsertItem(serverItem(id: id, version: 1, body: "v1"))
        try await queue.enqueueCreateItem(
            CreateItemInput(type: "core.note", properties: ["body": .string("v1")], id: id),
            localId: id
        )

        // The lost-response case: the server already holds this row, so it
        // writes nothing and hands back what it has — which has moved on from
        // what this device wrote.
        transport.enqueue(AcknowledgedItemBody(
            item: serverItem(id: id, version: 7, body: "what the server holds"),
            metadata: Metadata(extensions: [:], itemId: id, tags: ["from-the-server"]),
            acknowledged: true
        ))

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        #expect(try await queue.isEmpty)
        let stored = try await store.fetchItem(id: id)
        #expect(stored.version == 7)
        #expect(stored.properties["body"] == .string("what the server holds"))
        #expect(try await store.fetchMetadata(itemId: id).tags == ["from-the-server"])

        // Adopted, not dead-lettered.
        #expect(try await queue.fetchDropped().isEmpty)
    }

    @Test("a store that refuses the adopted row keeps the create queued")
    func adoptionFailureKeepsTheMutationQueued() async throws {
        let (_, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await SyncEngineTestKit.markImported(queue)
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport,
            localStore: RefusingLocalStore(),
            mutationQueue: queue,
            connectionManager: connManager
        )

        let id = UUIDv7.generateString()
        try await queue.enqueueCreateItem(
            CreateItemInput(type: "core.note", properties: ["body": .string("v1")], id: id),
            localId: id
        )
        transport.enqueue(ItemResponse(item: serverItem(id: id, version: 2, body: "v1")))

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // The server accepted the write, but this device did not store what
        // came back. Removing the record would strand the device on the row it
        // minted with nothing left to correct it, so the mutation stays for
        // the next drain — and it is not a permanent drop either.
        #expect(try await queue.isEmpty == false)
        #expect(try await queue.fetchDropped().isEmpty)
    }

    // MARK: - The refusal

    @Test("a conflict on a create is dropped once with the server's code, and never retried")
    func createConflictIsDroppedOnce() async throws {
        let (store, queue, transport, connManager, engine) =
            try await SyncEngineTestKit.makeFixture()

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

        transport.enqueueError(
            serverError(status: 409, code: "conflict",
                        message: "Item with id=\(id) already exists")
        )

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        #expect(try await queue.isEmpty)

        // Dead-lettered with what the server said, so an app can explain it.
        let dropped = try await queue.fetchDropped()
        #expect(dropped.count == 1)
        let entry = try #require(dropped.first)
        #expect(entry.kind == .createItem)
        #expect(entry.localId == id)
        #expect(entry.errorStatus == 409)
        #expect(entry.errorCode == "conflict")

        // The ghost is purged; the dependents half is the cascade's own test.
        #expect((try? await store.fetchItem(id: id)) == nil)

        let collected = await collector.value
        let drop = collected.first { if case .mutationDropped = $0 { return true } else { return false } }
        #expect(drop != nil)
        if case let .mutationDropped(kind, itemId, attempt, error) = drop {
            #expect(kind == "createItem")
            #expect(itemId == id)
            #expect(attempt == 1)
            #expect(error.status == 409)
        }

        // Gone rather than merely quiet: a second drain sends nothing, which
        // is the half an empty-queue assertion alone cannot distinguish from a
        // record waiting for the next cycle.
        let callsAfterDrop = transport.calls.count
        await engine.triggerProactiveDrainForTesting()
        #expect(transport.calls.count == callsAfterDrop)
    }

    @Test("a conflict on an edge create is dropped with its code and the local edge removed")
    func edgeCreateConflictIsDropped() async throws {
        let (store, queue, transport, connManager, engine) =
            try await SyncEngineTestKit.makeFixture()

        let edgeId = UUIDv7.generateString()
        try await store.upsertEdge(localEdge(id: edgeId, source: "A", target: "B"))
        try await queue.enqueueCreateEdge(
            source: "A", target: "B", edgeType: "in-thread",
            properties: nil, localEdgeId: edgeId
        )

        transport.enqueueError(
            serverError(status: 409, code: "conflict",
                        message: "Edge with id=\(edgeId) already exists")
        )

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        #expect(try await queue.isEmpty)
        let dropped = try await queue.fetchDropped()
        #expect(dropped.count == 1)
        let entry = try #require(dropped.first)
        #expect(entry.kind == .createEdge)
        #expect(entry.errorStatus == 409)
        #expect(entry.errorCode == "conflict")

        // The local edge names a row the server holds for somebody else, so
        // nothing on this device can ever reconcile it.
        #expect((try? await store.fetchEdge(id: edgeId)) == nil)
    }

    @Test("an edge create refused as a duplicate triple also loses its local row")
    func edgeCreateValidationFailureRemovesTheLocalRow() async throws {
        let (store, queue, transport, connManager, engine) =
            try await SyncEngineTestKit.makeFixture()

        let edgeId = UUIDv7.generateString()
        try await store.upsertEdge(localEdge(id: edgeId, source: "A", target: "B"))
        try await queue.enqueueCreateEdge(
            source: "A", target: "B", edgeType: "in-thread",
            properties: nil, localEdgeId: edgeId
        )

        // The reachable 400 on this door: the triple already exists, which
        // `assertEdgeCanBeCreated` refuses before any insert. Removing the row
        // is a rule about permanent refusals rather than about conflicts, and
        // this is the one that is not a conflict.
        transport.enqueueError(
            serverError(status: 400, code: "edge_constraint_violation",
                        message: "Edge A -> B of type in-thread already exists")
        )

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        #expect(try await queue.isEmpty)
        let entry = try #require(try await queue.fetchDropped().first)
        #expect(entry.kind == .createEdge)
        #expect(entry.errorStatus == 400)
        #expect((try? await store.fetchEdge(id: edgeId)) == nil)
    }

    // MARK: - The update path is untouched

    @Test("a conflict on an update is not a create's conflict: nothing is dead-lettered")
    func updateConflictIsNotDeadLettered() async throws {
        let (store, queue, transport, connManager, engine) =
            try await SyncEngineTestKit.makeFixture()

        let id = UUIDv7.generateString()
        try await store.upsertItem(serverItem(id: id, version: 1, body: "v1"))
        // Unversioned, so the replay sends a plain PATCH rather than entering
        // the conflict handler — the shape that surfaces a 409 as a thrown
        // error in the same catch chain a create's 409 now takes. Carrying a
        // `sourceId` is how that happens in practice: the natural key is
        // unique per space and the server answers `409 source_id_conflict`.
        try await queue.enqueueUpdateItem(
            id: id,
            properties: ["body": .string("v2")],
            version: nil,
            conflict: nil,
            tier: nil,
            sourceId: "upstream-1"
        )

        transport.enqueueError(
            serverError(status: 409, code: "source_id_conflict",
                        message: "source_id upstream-1 is already in use")
        )

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // The create rule is keyed on the pair — this status, on a create — so
        // an update meeting the same status is untouched by it and reaches no
        // dead-letter. What happens to it instead is
        // `SyncEngineBlockedMutationTests`; this asserts only the boundary.
        #expect(try await queue.fetchDropped().isEmpty)
    }
}
