import Foundation
import Marfa
import Testing

/// Items, tags and extensions on a copy that never reached a server, with the
/// built-in catalog.
@Suite(.timeLimit(.minutes(1)))
struct ItemsOffline {
    static func note(
        _ title: String, in copy: WorkingCopy, body: String = "b", tags: [String] = [], at occurredAt: String? = nil,
        tier: Tier? = nil
    ) async throws -> String {
        try #require(
            try await copy.items.create(
                Draft(
                    type: "core.note", properties: ["title": .string(title), "body": .string(body)], tags: tags,
                    tier: tier, occurredAt: occurredAt)
            ).itemId)
    }

    static func invalid(_ error: any Error) -> Bool {
        if case .invalid? = error as? MarfaError { true } else { false }
    }

    static func notFound(_ code: String) -> (any Error) -> Bool {
        { error in
            if case .notFound(let given, _)? = error as? MarfaError { given == code } else { false }
        }
    }

    @Test(arguments: CopyKind.allCases)
    func aCreatedItemIsHeldAtOnceAndQueuedWithItsTagsBehindIt(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let write = try await copy.items.create(
            Draft(type: "core.note", properties: ["title": "A", "body": "text"], tags: ["y", "x"]))
        let id = try #require(write.itemId)

        let held = try #require(try await copy.items.get(id))
        #expect(held.type == "core.note")
        #expect(held.state == .active)
        #expect(held.tier == .library)
        #expect(held.version == 0)
        #expect(held.schemaVersion == 1)
        #expect(held.source == "device")
        #expect(held.tags == ["x", "y"])
        #expect(held.title == "A")
        #expect(held.body == "text")
        #expect(held.properties == ["body": "text", "title": "A"])

        #expect(write.kind == .createItem)
        #expect(write.verdict == nil && !write.waiting && write.dependsOn.isEmpty && write.follows == nil)
        #expect(write.body["id"] == .string(id))
        #expect(write.body["type"] == "core.note")
        #expect(write.body["tier"] == "library")
        #expect(write.body["properties"]?.object == ["body": "text", "title": "A"])
        let queue = try await copy.queue.all()
        #expect(queue.map(\.kind) == [.createItem, .addTag, .addTag])
        #expect(queue[0] == write)
        #expect(queue[1...].map(\.tag) == ["y", "x"])
        #expect(queue[1...].allSatisfy { $0.dependsOn == [write.id] && $0.body["tags"]?.array?.count == 1 })
        #expect(queue[1].follows == write.id && queue[2].follows == queue[1].id)
        #expect(Set(queue.map(\.idempotencyKey)).count == 3)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aCreateIsRefusedBeforeAnythingIsQueuedForAnUnknownTypeAMissingFieldOrABadId(kind: CopyKind) async throws {
        let copy = try await kind.open()
        await #expect {
            _ = try await copy.items.create(Draft(type: "app.nope.type"))
        } throws: { error in
            if case .unknownType? = error as? MarfaError { true } else { false }
        }
        await #expect {
            _ = try await copy.items.create(Draft(type: "core.note", properties: ["title": "no body"]))
        } throws: { error in
            if case .validation("invalid_properties", let message)? = error as? MarfaError {
                message.contains("body")
            } else {
                false
            }
        }
        await #expect {
            _ = try await copy.items.create(Draft(type: "core.note", properties: ["body": "b"], id: "not-an-id"))
        } throws: { error in
            if case .validation("invalid_id", _)? = error as? MarfaError { true } else { false }
        }
        #expect(try await copy.queue.all().isEmpty)
        let id = "01a1500d-78bd-73f0-8c55-2a4160c5ff99"
        let write = try await copy.items.create(Draft(type: "core.note", properties: ["body": "b"], id: id))
        #expect(write.itemId == id)
        #expect(try await copy.items.get(id)?.id == id)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEditChangesTheHeldRowAtOnceAndIsQueuedBehindTheCreate(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let id = try await Self.note("A", in: copy)
        let created = try #require(try await copy.queue.all().first)

        let write = try await copy.items.update(id, Edit(properties: ["title": "B"], baseVersion: 0))

        #expect(write.kind == .updateItem)
        #expect(write.baseVersion == 0)
        #expect(write.body == ["properties": ["title": "B"], "version": 0])
        #expect(write.dependsOn == [created.id] && write.follows == created.id)
        let held = try #require(try await copy.items.get(id))
        #expect(held.properties == ["body": "b", "title": "B"])
        #expect(held.title == "B")
        #expect(held.version == 0)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEditIsRefusedForAStaleVersionAMissingItemOrAnUnknownTypeAndQueuesNothing(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let id = try await Self.note("A", in: copy)
        let before = try await copy.queue.all()
        await #expect {
            _ = try await copy.items.update(id, Edit(properties: ["title": "B"], baseVersion: 5))
        } throws: { error in
            guard case .invalid(let message)? = error as? MarfaError else { return false }
            return message.contains("version 5") && message.contains("version 0")
        }
        await #expect {
            _ = try await copy.items.updateAsRead(id, Edit(properties: ["title": "B"], baseVersion: 5))
        } throws: { Self.invalid($0) }
        await #expect {
            _ = try await copy.items.update("absent", Edit(baseVersion: 0))
        } throws: { Self.notFound("item_not_found")($0) }
        await #expect {
            _ = try await copy.items.update(id, Edit(baseVersion: 0, type: "app.nope.type"))
        } throws: { error in
            if case .unknownType? = error as? MarfaError { true } else { false }
        }
        #expect(try await copy.queue.all() == before)
        #expect(try await copy.items.get(id)?.title == "A")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEditThatMovesATierOrATypeIsSentOnlyWhereItChangesIt(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let id = try await Self.note("A", in: copy)
        let same = try await copy.items.update(id, Edit(baseVersion: 0, type: "core.note", tier: .library))
        #expect(same.body["type"] == nil && same.body["retype"] == nil && same.body["tier"] == nil)
        let moved = try await copy.items.update(id, Edit(baseVersion: 0, type: "core.task", tier: .feed))
        #expect(moved.body["type"] == "core.task" && moved.body["retype"] == true && moved.body["tier"] == "feed")
        let held = try #require(try await copy.items.get(id))
        #expect(held.type == "core.task" && held.tier == .feed)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aDeletedItemLeavesReadsAndListsUntilRestored(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let id = try await Self.note("A", in: copy)

        let deleted = try await copy.items.delete(id)
        #expect(deleted.kind == .deleteItem && deleted.baseVersion == 0 && deleted.body == ["version": 0])
        #expect(try await copy.items.get(id) == nil)
        #expect(try await copy.items.list().isEmpty)
        let binned = try await copy.items.list(ListFilters(allStates: true))
        #expect(binned.map(\.id) == [id] && binned.first?.state == .trashed)

        let restored = try await copy.items.restore(id)
        #expect(restored.kind == .restoreItem && restored.body == [:] && restored.follows == deleted.id)
        #expect(try await copy.items.get(id)?.state == .active)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aTransitionedItemIsListedByItsStateOnly(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let kept = try await Self.note("kept", in: copy)
        let archived = try await Self.note("archived", in: copy)

        let write = try await copy.items.transition(archived, to: .archived)

        #expect(write.kind == .transitionItem && write.body == ["state": "archived"])
        #expect(try await copy.items.get(archived)?.state == .archived)
        #expect(try await copy.items.list().map(\.id) == [kept])
        #expect(try await copy.items.list(ListFilters(state: .archived)).map(\.id) == [archived])
        #expect(Set(try await copy.items.list(ListFilters(allStates: true)).map(\.id)) == [kept, archived])
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func tagsChangeTheHeldRowAndQueueOneWriteEach(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let id = try await Self.note("A", in: copy, tags: ["x", "y"])

        let added = try await copy.tags.add("z", to: id)
        #expect(added.kind == .addTag && added.tag == "z" && added.body == ["tags": ["z"]])
        let removed = try await copy.tags.remove("x", from: id)
        #expect(removed.kind == .removeTag && removed.tag == "x" && removed.body == [:])
        #expect(try await copy.items.get(id)?.tags == ["y", "z"])

        let replaced = try await copy.metadata.replaceTags(of: id, with: ["q"])
        #expect(replaced.kind == .replaceMetadata && replaced.body == ["tags": ["q"]])
        #expect(try await copy.items.get(id)?.tags == ["q"])
        let merged = try await copy.metadata.mergeTags(["r", "q"], into: id)
        #expect(merged.kind == .mergeMetadata && merged.body == ["tags": ["r", "q"]])
        #expect(try await copy.items.get(id)?.tags == ["q", "r"])
        await #expect {
            _ = try await copy.tags.add("z", to: "absent")
        } throws: { Self.notFound("item_not_found")($0) }
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anExtensionIsQueuedAsItsOwnWriteForAnItemTheCopyHolds(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let id = try await Self.note("A", in: copy)

        let written = try await copy.extensions.write("acme.x", ["a": 1], on: id)
        let deleted = try await copy.extensions.delete("acme.x", from: id)

        #expect(written.kind == .writeExtension && written.namespace == "acme.x" && written.body == ["a": 1])
        #expect(deleted.kind == .deleteExtension && deleted.namespace == "acme.x" && deleted.follows == written.id)
        await #expect {
            _ = try await copy.extensions.write("acme.x", [:], on: "absent")
        } throws: { Self.notFound("item_not_found")($0) }
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aListNarrowsByTypeTagsTierAndStateAndOrdersBySortWithLimitAndOffset(kind: CopyKind) async throws {
        let copy = try await kind.open(declaring: [["id": "app.notes.memo", "parent": "core.note"]])
        let first = try await Self.note("first", in: copy, tags: ["a"], at: "2026-01-01T00:00:00.000Z")
        let second = try await Self.note("second", in: copy, tags: ["a", "b"], at: "2026-01-02T00:00:00.000Z")
        let third = try await Self.note(
            "third", in: copy, at: "2026-01-03T00:00:00.000Z", tier: .feed)
        let memo = try #require(
            try await copy.items.create(
                Draft(type: "app.notes.memo", properties: ["body": "m"], occurredAt: "2026-01-04T00:00:00.000Z")
            ).itemId)
        let task = try #require(
            try await copy.items.create(
                Draft(type: "core.task", properties: ["title": "t"], occurredAt: "2026-01-05T00:00:00.000Z")
            ).itemId)
        let ascending = Sort(field: .occurredAt, direction: .ascending)

        #expect(try await copy.items.list(sort: ascending).map(\.id) == [first, second, third, memo, task])
        #expect(try await copy.items.list().map(\.id) == [task, memo, third, second, first])
        #expect(
            try await copy.items.list(ListFilters(type: "core.note"), sort: ascending).map(\.id) == [
                first, second, third, memo,
            ])
        #expect(try await copy.items.list(ListFilters(type: "core.task"), sort: ascending).map(\.id) == [task])
        #expect(try await copy.items.list(ListFilters(type: "*"), sort: ascending).count == 5)
        #expect(try await copy.items.list(ListFilters(tags: ["a"]), sort: ascending).map(\.id) == [first, second])
        #expect(try await copy.items.list(ListFilters(tags: ["a", "b"]), sort: ascending).map(\.id) == [second])
        #expect(try await copy.items.list(ListFilters(tier: .feed), sort: ascending).map(\.id) == [third])
        #expect(
            try await copy.items.list(ListFilters(limit: 2, offset: 1), sort: ascending).map(\.id) == [second, third])
        #expect(try await copy.items.list(ListFilters(offset: 9), sort: ascending).isEmpty)
        await #expect {
            _ = try await copy.items.list(ListFilters(type: "Not A Type"))
        } throws: { error in
            if case .validation("validation_error", _)? = error as? MarfaError { true } else { false }
        }
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aListBeneathAnItemHoldsItAndWhatItReachesAlongParentOf(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let root = try await Self.note("root", in: copy)
        let child = try await Self.note("child", in: copy)
        let grandchild = try await Self.note("grandchild", in: copy)
        let apart = try await Self.note("apart", in: copy)
        _ = try await copy.edges.create(from: root, to: child, type: "parent-of")
        _ = try await copy.edges.create(from: child, to: grandchild, type: "parent-of")
        _ = try await copy.edges.create(from: root, to: apart, type: "references")

        let beneath = try await copy.items.list(
            ListFilters(beneath: root), sort: Sort(field: .createdAt, direction: .ascending))

        #expect(beneath.map(\.id) == [root, child, grandchild])
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEdgeIsHeldAtOnceAndQueuedBehindTheCreatesOfBothItems(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let source = try await Self.note("source", in: copy)
        let target = try await Self.note("target", in: copy)
        let creates = try await copy.queue.all().filter { $0.kind == .createItem }.map(\.id)

        let write = try await copy.edges.create(from: source, to: target, type: "references", properties: ["n": 1])
        let edgeId = try #require(write.edgeId)

        #expect(write.kind == .createEdge && write.itemId == source && write.targetId == target)
        #expect(write.dependsOn == creates && write.follows == nil)
        #expect(write.body["edge_type"] == "references" && write.body["id"] == .string(edgeId))
        #expect(write.body["source_id"] == .string(source) && write.body["target_id"] == .string(target))
        let held = try #require(try await copy.edges.from(source).first)
        #expect(held.id == edgeId && held.targetId == target && held.edgeType == "references")
        #expect(held.properties == ["n": 1] && held.version == 0)
        #expect(try await copy.edges.to(target).map(\.id) == [edgeId])
        #expect(try await copy.edges.ofType("references").map(\.id) == [edgeId])
        #expect(try await copy.edges.ofType("about").isEmpty)

        let deleted = try await copy.edges.delete(edgeId)
        #expect(deleted.kind == .deleteEdge && deleted.body == ["edge_type": "references"])
        #expect(deleted.dependsOn == [write.id] && deleted.follows == write.id)
        #expect(try await copy.edges.from(source).isEmpty)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEdgeFromAnItemTheCopyDoesNotHoldOrBackToItsSourceIsRefused(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let held = try await Self.note("held", in: copy)
        await #expect {
            _ = try await copy.edges.create(from: "01a1500d-78bd-73f0-8c55-2a4160c5ff99", to: held, type: "about")
        } throws: { Self.invalid($0) }
        await #expect {
            _ = try await copy.edges.create(from: held, to: held, type: "about")
        } throws: { error in
            if case .validation("edge_cycle", _)? = error as? MarfaError { true } else { false }
        }
        await #expect {
            _ = try await copy.edges.delete("absent")
        } throws: { Self.notFound("edge_not_found")($0) }
        #expect(try await copy.queue.all().count == 1)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aCopyThatNothingHasAnsweredHoldsNoVerdictAndRefusesWhatOnlyAnAnswerCouldAllow(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let id = try await Self.note("A", in: copy)
        let write = try #require(try await copy.queue.all().first)
        #expect(write.itemId == id)

        #expect(try await copy.queue.withdraw(write.id) == false)
        #expect(try await copy.queue.discard(write.id) == false)
        #expect(try await copy.queue.forgetAnswered() == 0)
        #expect(try await copy.queue.forgetAnswered(ids: [write.id]) == 0)
        await #expect {
            _ = try await copy.queue.withdraw("absent")
        } throws: { Self.notFound("queued_write_not_found")($0) }
        await #expect {
            _ = try await copy.queue.discard("absent")
        } throws: { Self.notFound("queued_write_not_found")($0) }
        #expect(try await copy.queue.all() == [write])
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func theStatusCountsWhatTheCopyHoldsAndHasNeverHydrated(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let a = try await Self.note("a", in: copy)
        let b = try await Self.note("b", in: copy)
        _ = try await copy.edges.create(from: a, to: b, type: "references")

        let status = try await copy.status()

        #expect(status.items == 2 && status.edges == 1)
        #expect(status.hydration == .never)
        #expect(status.serverOrigin == nil && status.eventCursor == nil && status.sliceTypes.isEmpty)
        #expect(copy.handle == .writer)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func theCatalogAnswersByIdAndSaysWhichTypeItDoesNotHold(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let note = try await copy.catalog.itemType("core.note")
        #expect(note.id == "core.note" && note.titleField == "title" && note.bodyField == "body")
        #expect(note.fields.first { $0.name == "body" }?.required == true)
        let ids = try await copy.catalog.itemTypes().map(\.id)
        #expect(ids == ids.sorted() && ids.contains("core.note"))
        let parentOf = try await copy.catalog.edgeType("parent-of")
        #expect(parentOf.cardinality == "one-to-many" && parentOf.reverseName == "child-of")
        #expect(parentOf.writtenAt == .target)
        let edgeIds = try await copy.catalog.edgeTypes().map(\.id)
        #expect(edgeIds == edgeIds.sorted() && edgeIds.contains("references"))
        await #expect {
            _ = try await copy.catalog.itemType("app.nope.type")
        } throws: { Self.notFound("type_not_found")($0) }
        await #expect {
            _ = try await copy.catalog.edgeType("nope")
        } throws: { Self.notFound("edge_type_not_found")($0) }
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aClosedCopyRefusesEveryCall(kind: CopyKind) async throws {
        let copy = try await kind.open()
        await copy.close()
        await #expect {
            _ = try await copy.items.list()
        } throws: { error in
            if case .closed? = error as? MarfaError { true } else { false }
        }
        await #expect {
            _ = try await copy.items.create(Draft(type: "core.note", properties: ["body": "b"]))
        } throws: { error in
            if case .closed? = error as? MarfaError { true } else { false }
        }
    }

    @Test(arguments: CopyKind.allCases)
    func aCopyWithNoServerRefusesAKeyAndTellsItsOwnWrites(kind: CopyKind) async throws {
        let copy = try await kind.open()
        await #expect {
            try await copy.useKey("k")
        } throws: { error in
            if case .noServer? = error as? MarfaError { true } else { false }
        }
        let heard = Heard(copy.changes())
        let id = try await Self.note("A", in: copy)
        try await eventually("the create was told") { !heard.locals.isEmpty }
        #expect(heard.locals.first?.origin == .local(.createItem))
        #expect(heard.locals.first?.itemId == id)
        await copy.close()
    }
}
