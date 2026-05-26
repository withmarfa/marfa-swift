import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// MutationQueue fundamentals: enqueue / fetch / remove / cursor persistence /
/// per-kind helpers / drain stream broadcast.
///
/// Shared helpers live in ``SyncEngineTestKit`` (see SyncEngineTestSupport.swift).
@Suite("MutationQueue")
struct MutationQueueTests {

    @Test("Queue starts empty") func startsEmpty() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        #expect(try await queue.isEmpty)
    }

    @Test("Enqueue createItem appears in fetchAll") func enqueueCreateItem() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        let input = CreateItemInput(type: "core.note", properties: ["body": .string("hi")])
        try await queue.enqueueCreateItem(input, localId: "local-123")

        let records = try await queue.fetchAll()
        #expect(records.count == 1)
        #expect(records[0].kind == .createItem)
        #expect(records[0].localId == "local-123")
        #expect(try await queue.isEmpty == false)
    }

    @Test("remove deletes a record") func removeRecord() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        try await queue.enqueueCreateItem(input, localId: "l1")

        let records = try await queue.fetchAll()
        #expect(records.count == 1)
        try await queue.remove(id: records[0].id)
        #expect(try await queue.isEmpty)
    }

    @Test("recordFailure increments attempt_count") func recordFailure() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        try await queue.enqueueDeleteItem(id: "item-1")

        var records = try await queue.fetchAll()
        let id = records[0].id
        #expect(records[0].attemptCount == 0)

        try await queue.recordFailure(id: id, error: "network error")
        records = try await queue.fetchAll()
        #expect(records[0].attemptCount == 1)
        #expect(records[0].lastError == "network error")
    }

    @Test("fetchAll returns records in creation order") func fetchAllOrder() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        try await queue.enqueueDeleteItem(id: "a")
        try await queue.enqueueDeleteItem(id: "b")
        try await queue.enqueueDeleteItem(id: "c")

        let records = try await queue.fetchAll()
        #expect(records.count == 3)
        // All three should be present; creation order preserved by created_at ordering.
        let localIds = records.compactMap { $0.localId }
        #expect(localIds.contains("a"))
        #expect(localIds.contains("b"))
        #expect(localIds.contains("c"))
    }

    @Test("saveSyncState and loadSyncState round-trip") func syncStateCursor() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()

        let loaded = try await queue.loadSyncState(key: "last_event_id")
        #expect(loaded == nil)

        try await queue.saveSyncState(key: "last_event_id", value: "evt-42")
        let reloaded = try await queue.loadSyncState(key: "last_event_id")
        #expect(reloaded == "evt-42")

        // Update
        try await queue.saveSyncState(key: "last_event_id", value: "evt-99")
        let updated = try await queue.loadSyncState(key: "last_event_id")
        #expect(updated == "evt-99")
    }

    @Test("enqueue all mutation kinds") func enqueueAllKinds() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])

        try await queue.enqueueCreateItem(input, localId: "li")
        try await queue.enqueueUpdateItem(id: "i1", properties: ["body": .string("y")])
        try await queue.enqueueDeleteItem(id: "i2")
        try await queue.enqueueRestoreItem(id: "i3")
        try await queue.enqueueTransitionItem(id: "i4", to: .archived)
        try await queue.enqueuePurgeItem(id: "i5")
        try await queue.enqueueCreateEdge(source: "a", target: "b", edgeType: "about", properties: nil, localEdgeId: "e1")
        try await queue.enqueueUpdateEdge(id: "e2", properties: ["note": .string("x")])
        try await queue.enqueueDeleteEdge(id: "e3")
        try await queue.enqueueSetMetadata(itemId: "i6", input: MetadataInput(tags: ["a"]))
        try await queue.enqueueMergeMetadata(itemId: "i7", input: MetadataInput(tags: ["b"]))
        try await queue.enqueueAddTags(itemId: "i8", tags: ["c"])
        try await queue.enqueueRemoveTag(itemId: "i9", tag: "d")

        let records = try await queue.fetchAll()
        #expect(records.count == 13)
        let kinds = records.map(\.kind)
        #expect(kinds.contains(.createItem))
        #expect(kinds.contains(.updateItem))
        #expect(kinds.contains(.deleteItem))
        #expect(kinds.contains(.restoreItem))
        #expect(kinds.contains(.transitionItem))
        #expect(kinds.contains(.purgeItem))
        #expect(kinds.contains(.createEdge))
        #expect(kinds.contains(.updateEdge))
        #expect(kinds.contains(.deleteEdge))
        #expect(kinds.contains(.setMetadata))
        #expect(kinds.contains(.mergeMetadata))
        #expect(kinds.contains(.addTags))
        #expect(kinds.contains(.removeTag))
    }

    @Test("enqueueUpdateItem captures version + conflict + library on the payload") func captureUpdateOptions() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        try await queue.enqueueUpdateItem(
            id: "i1",
            properties: ["body": .string("x")],
            version: 5,
            conflict: .manual,
            tier: .library
        )
        let records = try await queue.fetchAll()
        let updateRecord = try #require(records.first { $0.kind == .updateItem })
        let payload = try JSONDecoder().decode(
            UpdateItemPayload.self,
            from: updateRecord.payloadJson.data(using: .utf8) ?? Data()
        )
        #expect(payload.version == 5)
        #expect(payload.conflict == .manual)
        #expect(payload.tier == .library)
    }

    @Test("enqueueUpdateItem with no options leaves version/conflict/library nil") func captureNoUpdateOptions() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()
        try await queue.enqueueUpdateItem(
            id: "i1",
            properties: ["body": .string("x")]
        )
        let records = try await queue.fetchAll()
        let updateRecord = try #require(records.first { $0.kind == .updateItem })
        let payload = try JSONDecoder().decode(
            UpdateItemPayload.self,
            from: updateRecord.payloadJson.data(using: .utf8) ?? Data()
        )
        #expect(payload.version == nil)
        #expect(payload.conflict == nil)
        #expect(payload.tier == nil)
    }

    @Test("drainRequests yields once per enqueue across every MutationKind helper")
    func drainRequestsYieldsPerEnqueue() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()

        // `drainRequests` is an async actor property — awaiting it
        // returns a stream whose continuation is already registered,
        // so pings fired on the very next enqueue are guaranteed to
        // land.
        let stream = await queue.drainRequests
        var iter = stream.makeAsyncIterator()

        // One call per MutationKind case (19 in total). Consume each
        // ping as we go so nothing is buffered out of order.
        let kinds: [() async throws -> Void] = [
            {
                try await queue.enqueueCreateItem(
                    CreateItemInput(type: "core.note", properties: [:]),
                    localId: "l1"
                )
            },
            { try await queue.enqueueUpdateItem(id: "l1", properties: [:]) },
            { try await queue.enqueueDeleteItem(id: "l1") },
            { try await queue.enqueueRestoreItem(id: "l1") },
            { try await queue.enqueueTransitionItem(id: "l1", to: .archived) },
            { try await queue.enqueuePurgeItem(id: "l1") },
            {
                try await queue.enqueueCreateEdge(
                    source: "a", target: "b", edgeType: "x.y", properties: nil, localEdgeId: "e1"
                )
            },
            { try await queue.enqueueUpdateEdge(id: "e1", properties: [:]) },
            { try await queue.enqueueDeleteEdge(id: "e1") },
            { try await queue.enqueueSetMetadata(itemId: "l1", input: MetadataInput(tags: [])) },
            { try await queue.enqueueMergeMetadata(itemId: "l1", input: MetadataInput(tags: [])) },
            { try await queue.enqueueAddTags(itemId: "l1", tags: ["t"]) },
            { try await queue.enqueueRemoveTag(itemId: "l1", tag: "t") },
            { try await queue.enqueueSetExtension(itemId: "l1", namespace: "ns", data: [:]) },
            { try await queue.enqueueDeleteExtension(itemId: "l1", namespace: "ns") },
            { try await queue.enqueueBulk(BulkInput(items: [])) },
            {
                try await queue.enqueueBulkAction(
                    .transition(filter: BulkActionFilter(), state: .archived)
                )
            },
            { try await queue.enqueueBulkEdges(BulkEdgeInput(edges: [])) },
            {
                try await queue.enqueueBlobUpload(
                    hash: "sha256:deadbeef", data: Data([0x01, 0x02]), mimeType: "application/octet-stream"
                )
            },
        ]

        for fire in kinds {
            try await fire()
            let ping: Void? = await iter.next()
            #expect(ping != nil)
        }
    }
}
