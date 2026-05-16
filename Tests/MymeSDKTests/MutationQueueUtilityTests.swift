import Testing
import Foundation
@testable import MymeSDK
@testable import MymeSDKTestSupport

/// MutationQueue utility methods: `rewriteLocalId` and
/// `dropMutationsReferencingLocalId`. Both rewrite or drop rows across the
/// queue in support of reconciling local IDs with server-assigned ones.
///
/// Shared helpers live in ``SyncEngineTestKit`` (see SyncEngineTestSupport.swift).
@Suite("MutationQueue utilities")
struct MutationQueueUtilityTests {

    // MARK: - rewriteLocalId

    @Test("rewrites update and edge endpoint references, leaves createItem alone")
    func rewritesDependents() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()

        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        try await queue.enqueueCreateItem(input, localId: "A")
        try await queue.enqueueUpdateItem(id: "A", properties: ["body": .string("y")])
        try await queue.enqueueCreateEdge(
            source: "A", target: "B", edgeType: "about", properties: nil, localEdgeId: "E1"
        )

        try await queue.rewriteLocalId(from: "A", to: "A'")

        let records = try await queue.fetchAll()

        // createItem: localId unchanged (it owns "A" as its identity).
        let create = try #require(records.first { $0.kind == .createItem })
        #expect(create.localId == "A")

        // updateItem: localId and payload.id both rewritten to "A'".
        let update = try #require(records.first { $0.kind == .updateItem })
        #expect(update.localId == "A'")
        let updatePayload = try JSONDecoder().decode(
            UpdateItemPayload.self,
            from: update.payloadJson.data(using: .utf8) ?? Data()
        )
        #expect(updatePayload.id == "A'")

        // createEdge: source rewritten to "A'", target unchanged.
        let edge = try #require(records.first { $0.kind == .createEdge })
        let edgePayload = try JSONDecoder().decode(
            CreateEdgePayload.self,
            from: edge.payloadJson.data(using: .utf8) ?? Data()
        )
        #expect(edgePayload.source == "A'")
        #expect(edgePayload.target == "B")
    }

    @Test("rewrites target endpoint when oldId was on the target side of an edge")
    func rewritesEdgeTargetEndpoint() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()

        try await queue.enqueueCreateEdge(
            source: "X", target: "A", edgeType: "about", properties: nil, localEdgeId: "E1"
        )

        try await queue.rewriteLocalId(from: "A", to: "A'")

        let records = try await queue.fetchAll()
        let edge = try #require(records.first { $0.kind == .createEdge })
        let payload = try JSONDecoder().decode(
            CreateEdgePayload.self,
            from: edge.payloadJson.data(using: .utf8) ?? Data()
        )
        #expect(payload.source == "X")
        #expect(payload.target == "A'")
    }

    @Test("rewrites metadata / tags / extension kinds keyed off item id")
    func rewritesMetadataAndExtensions() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()

        try await queue.enqueueSetMetadata(itemId: "A", input: MetadataInput(tags: ["a"]))
        try await queue.enqueueAddTags(itemId: "A", tags: ["b"])
        try await queue.enqueueRemoveTag(itemId: "A", tag: "c")
        try await queue.enqueueSetExtension(
            itemId: "A", namespace: "com.example", data: ["k": .string("v")]
        )
        try await queue.enqueueDeleteExtension(itemId: "A", namespace: "com.example")

        try await queue.rewriteLocalId(from: "A", to: "Z")

        let records = try await queue.fetchAll()
        for record in records {
            #expect(record.localId == "Z", "\(record.kind) should have localId rewritten")
        }

        let meta = try #require(records.first { $0.kind == .setMetadata })
        let metaPayload = try JSONDecoder().decode(
            MetadataPayload.self, from: meta.payloadJson.data(using: .utf8) ?? Data()
        )
        #expect(metaPayload.itemId == "Z")

        let addTags = try #require(records.first { $0.kind == .addTags })
        let addTagsPayload = try JSONDecoder().decode(
            AddTagsPayload.self, from: addTags.payloadJson.data(using: .utf8) ?? Data()
        )
        #expect(addTagsPayload.itemId == "Z")

        let setExt = try #require(records.first { $0.kind == .setExtension })
        let setExtPayload = try JSONDecoder().decode(
            SetExtensionPayload.self, from: setExt.payloadJson.data(using: .utf8) ?? Data()
        )
        #expect(setExtPayload.itemId == "Z")
    }

    @Test("no-op when from == to")
    func noOpOnEquality() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()

        try await queue.enqueueUpdateItem(id: "A", properties: ["body": .string("y")])
        try await queue.rewriteLocalId(from: "A", to: "A")

        let records = try await queue.fetchAll()
        #expect(records.count == 1)
        #expect(records[0].localId == "A")
    }

    // MARK: - dropMutationsReferencingLocalId

    @Test("drops item-scope mutations keyed on local_id, leaves createItem for caller")
    func dropsItemScope() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()

        let input = CreateItemInput(type: "core.note", properties: ["body": .string("x")])
        try await queue.enqueueCreateItem(input, localId: "A")
        try await queue.enqueueUpdateItem(id: "A", properties: ["body": .string("y")])
        try await queue.enqueueSetMetadata(itemId: "A", input: MetadataInput(tags: ["t"]))
        try await queue.enqueueDeleteItem(id: "A")

        let deleted = try await queue.dropMutationsReferencingLocalId(
            "A",
            droppedAt: Date(),
            error: ValidationError(message: "test")
        )

        // Everything keyed off "A" was scheduled for drop, except the
        // createItem root (the caller removes that separately so their
        // own `.mutationDropped` emit fires for the root failure).
        #expect(deleted.count == 3)
        let kinds = Set(deleted.map { $0.kind })
        #expect(kinds == Set([.updateItem, .setMetadata, .deleteItem]))

        let remaining = try await queue.fetchAll()
        #expect(remaining.count == 1)
        #expect(remaining[0].kind == .createItem)
    }

    @Test("drops createEdge rows whose source or target matches the local id")
    func dropsEdgesByEndpoint() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()

        try await queue.enqueueCreateEdge(
            source: "A", target: "B", edgeType: "about",
            properties: nil, localEdgeId: "E-AB"
        )
        try await queue.enqueueCreateEdge(
            source: "X", target: "A", edgeType: "in-thread",
            properties: nil, localEdgeId: "E-XA"
        )
        try await queue.enqueueCreateEdge(
            source: "X", target: "Y", edgeType: "about",
            properties: nil, localEdgeId: "E-XY"
        )

        let deleted = try await queue.dropMutationsReferencingLocalId(
            "A",
            droppedAt: Date(),
            error: ValidationError(message: "test")
        )

        // Both A-touching edges cascade; the unrelated X→Y survives.
        #expect(deleted.count == 2)
        let remaining = try await queue.fetchAll()
        #expect(remaining.count == 1)
        #expect(remaining[0].localId == "E-XY")
    }

    @Test("drops updateEdge / deleteEdge follow-ups for cascade-deleted createEdge rows")
    func dropsEdgeFollowUps() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()

        // createEdge whose source is the dropped item; follow-up
        // updateEdge + deleteEdge reference the same edge id.
        try await queue.enqueueCreateEdge(
            source: "A", target: "B", edgeType: "about",
            properties: nil, localEdgeId: "E-AB"
        )
        try await queue.enqueueUpdateEdge(id: "E-AB", properties: ["note": .string("x")])
        try await queue.enqueueDeleteEdge(id: "E-AB")

        // Sibling edge not connected to A — its follow-ups should survive.
        try await queue.enqueueCreateEdge(
            source: "X", target: "Y", edgeType: "about",
            properties: nil, localEdgeId: "E-XY"
        )
        try await queue.enqueueUpdateEdge(id: "E-XY", properties: ["note": .string("z")])

        let deleted = try await queue.dropMutationsReferencingLocalId(
            "A",
            droppedAt: Date(),
            error: ValidationError(message: "test")
        )

        // createEdge + updateEdge + deleteEdge for E-AB, but NOT the
        // sibling E-XY or its updateEdge.
        #expect(deleted.count == 3)

        let remaining = try await queue.fetchAll()
        let remainingKinds = Set(remaining.map { $0.kind })
        #expect(remainingKinds == Set([.createEdge, .updateEdge]))
        let remainingLocalIds = Set(remaining.compactMap { $0.localId })
        #expect(remainingLocalIds == Set(["E-XY"]))
    }

    @Test("no-op when no rows reference the local id")
    func noOpWhenUnreferenced() async throws {
        let (_, queue) = try await SyncEngineTestKit.makeStoreAndQueue()

        try await queue.enqueueUpdateItem(id: "B", properties: ["body": .string("y")])
        let deleted = try await queue.dropMutationsReferencingLocalId(
            "A",
            droppedAt: Date(),
            error: ValidationError(message: "test")
        )
        #expect(deleted.isEmpty)
        #expect(try await queue.fetchAll().count == 1)
    }
}
