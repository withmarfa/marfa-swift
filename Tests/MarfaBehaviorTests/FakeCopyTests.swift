#if DEBUG
import Foundation
import Marfa
import MarfaTesting
import Observation
import Synchronization
import Testing

/// What only the fake does.
///
/// That is what it is given, what it refuses to do, and what a test can make it
/// do. A real copy with no server answers none of these.
@Suite(.timeLimit(.minutes(1)))
struct FakeCopyBehavior {
    static let note = Item(
        id: "01a1500d-78bd-73f0-8c55-2a4160c5ff01", type: "core.note", properties: ["title": "Seed", "body": "b"],
        state: .active, tier: .library, version: 4, schemaVersion: 1, source: "app", sourceId: nil,
        occurredAt: "2026-09-26T00:00:00.000Z", createdAt: "2026-09-26T00:00:00.000Z",
        updatedAt: "2026-09-26T00:00:00.000Z", tags: ["seed"], title: "Seed", body: "b")
    static let other = Item(
        id: "01a1500d-78bd-73f0-8c55-2a4160c5ff02", type: "core.note", properties: ["title": "Other", "body": "o"],
        state: .active, tier: .library, version: 1, schemaVersion: 1, source: "app", sourceId: nil,
        occurredAt: "2026-09-27T00:00:00.000Z", createdAt: "2026-09-27T00:00:00.000Z",
        updatedAt: "2026-09-27T00:00:00.000Z", tags: [], title: "Other", body: "o")
    static let edge = Edge(
        id: "01a1500d-78bd-73f0-8c55-2a4160c5ffe1", sourceId: note.id, targetId: other.id, edgeType: "references",
        properties: ["n": 1], version: 2, createdAt: "2026-09-27T00:00:00.000Z", updatedAt: "2026-09-27T00:00:00.000Z")
    static let noteType = ItemType(
        id: "core.note", fields: [TypeField(name: "body", type: "string", required: true, declaredBy: "core.note")],
        titleField: "title", bodyField: "body")
    static let references = EdgeType(
        id: "references", label: "References", reverseLabel: "Referenced by", cardinality: "many-to-many")

    static func seeded() -> FakeCopy {
        WorkingCopy.fake(
            items: [note, other], edges: [edge], itemTypes: [noteType], edgeTypes: [references])
    }

    func refusedAsUnsupported(_ call: String) -> (any Error) -> Bool {
        { error in (error as? FakeCopyError) == .unsupported(call: call) }
    }

    @Test func theCopyServesWhatItIsGiven() async throws {
        let fake = Self.seeded()
        let copy = fake.copy

        #expect(try await copy.items.get(Self.note.id) == Self.note)
        let listed = try await copy.items.list(sort: Sort(field: .occurredAt, direction: .ascending))
        #expect(listed.rows == [Self.note, Self.other])
        #expect(listed.completeness == .complete)
        #expect(try await copy.edges.from(Self.note.id) == [Self.edge])
        #expect(try await copy.edges.to(Self.other.id) == [Self.edge])
        #expect(try await copy.edges.ofType("references") == [Self.edge])
        #expect(try await copy.catalog.itemTypes() == [Self.noteType])
        #expect(try await copy.catalog.edgeType("references") == Self.references)
        #expect(try await copy.queue.all().isEmpty && fake.writes.isEmpty)
        let status = try await copy.status()
        #expect(status.items == 2 && status.edges == 1 && status.hydration == .never)
        #expect(copy.handle == .writer)
        await copy.close()
    }

    @Test func aWriteToASeededRowIsBasedOnTheVersionItWasGiven() async throws {
        let fake = Self.seeded()
        let write = try await fake.copy.items.update(
            Self.note.id, Edit(properties: ["title": "Edited"], baseVersion: 4))
        #expect(write.baseVersion == 4)
        #expect(try await fake.copy.items.get(Self.note.id)?.title == "Edited")
        await #expect {
            _ = try await fake.copy.items.update(Self.note.id, Edit(baseVersion: 0))
        } throws: { error in
            if case .invalid? = error as? MarfaError { true } else { false }
        }
        #expect(fake.writes == [write])
        await fake.copy.close()
    }

    @Test func aCreateOfATypeTheFakeWasNotGivenIsRefused() async throws {
        let fake = WorkingCopy.fake()
        await #expect {
            _ = try await fake.copy.items.create(Draft(type: "core.note", properties: ["body": "b"]))
        } throws: { error in
            if case .unknownType? = error as? MarfaError { true } else { false }
        }
        #expect(fake.writes.isEmpty)
        await fake.copy.close()
    }

    @Test func eachCallTheFakeDoesNotServeThrowsNamingTheCall() async throws {
        let copy = Self.seeded().copy
        let id = Self.note.id
        let file = URL(filePath: "/tmp/not-read.txt")
        let calls: [(String, @Sendable () async throws -> Void)] = [
            ("hydrate", { _ = try await copy.hydrate(types: ["core.note"], tier: .all) }),
            ("catchUp", { _ = try await copy.catchUp() }),
            ("pin", { _ = try await copy.pin(id) }),
            ("unpin", { _ = try await copy.unpin(id) }),
            ("items.bin", { _ = try await copy.items.bin() }),
            ("items.purge", { try await copy.items.purge(id) }),
            ("items.thumbnail", { _ = try await copy.items.thumbnail(id) }),
            ("items.attach", { _ = try await copy.items.attach(to: id, file: file) }),
            ("items.links", { _ = try await copy.items.links(in: id) }),
            ("items.embedText", { _ = try await copy.items.embedText(of: id, in: id) }),
            ("items.original", { _ = try await copy.items.original(ofConflictedCopy: id) }),
            ("items.conflictedCopies", { _ = try await copy.items.conflictedCopies(of: id) }),
            ("blobs.put", { _ = try await copy.blobs.put(file: file) }),
            ("blobs.withFile", { try await copy.blobs.withFile("hash") { _ in } }),
            ("blobs.isHeld", { _ = try await copy.blobs.isHeld("hash") }),
            ("blobs.cache", { _ = try await copy.blobs.cache() }),
            ("blobs.setBudget", { _ = try await copy.blobs.setBudget(.keepAll) }),
            ("blobs.trim", { _ = try await copy.blobs.trim() }),
            ("blobs.fetchKept", { _ = try await copy.blobs.fetchKept() }),
            ("queue.release", { _ = try await copy.queue.release(id) }),
            ("queue.release(reason:)", { _ = try await copy.queue.release(reason: .keySpent) }),
            ("items.list(filter:)", { _ = try await copy.items.list(ListFilters(filter: "x")) }),
            ("items.create(sourceId:)", { _ = try await copy.items.create(Draft(type: "core.note", sourceId: "k")) }),
            ("revokeFolder", { _ = try await copy.revokeFolder(id) }),
            ("search(filter:)", { _ = try await copy.search("seed", filters: SearchFilters(filter: "x")) }),
        ]
        for (call, make) in calls {
            await #expect(performing: { try await make() }, throws: refusedAsUnsupported(call))
        }
        #expect(try await copy.queue.all().isEmpty)
        await copy.close()
    }

    @Test func aStreamIsToldWhatATestSends() async throws {
        let fake = Self.seeded()
        let first = Heard(fake.copy.changes())
        let second = Heard(fake.copy.changes())
        let scripted = [
            Change(origin: .server(event: "item.updated", cursor: "7"), itemId: Self.note.id, edgeId: nil),
            Change(origin: .serverUnreachable(.network(message: "away")), itemId: nil, edgeId: nil),
            Change(origin: .refreshed(.hydrated), itemId: nil, edgeId: nil),
        ]

        for change in scripted { fake.send(change) }

        try await eventually("both streams were told") { first.all.count == 3 && second.all.count == 3 }
        #expect(first.all == scripted && second.all == scripted)
        await fake.copy.close()
    }

    @Test func aClosedCopyEndsItsStreams() async throws {
        let fake = Self.seeded()
        let stream = fake.copy.changes()
        await fake.copy.close()
        fake.send(Change(origin: .refreshed(.hydrated), itemId: nil, edgeId: nil))
        var told: [Change] = []
        for await change in stream { told.append(change) }
        #expect(told.isEmpty)
    }

    @Test func theWritesAreListedInOrderAndSurviveTheQueueForgettingThem() async throws {
        let fake = Self.seeded()
        let copy = fake.copy
        let created = try await copy.items.create(Draft(type: "core.note", properties: ["body": "b"], tags: ["t"]))
        let edited = try await copy.items.update(Self.note.id, Edit(properties: ["title": "E"], baseVersion: 4))
        let edge = try await copy.edges.create(from: Self.note.id, to: Self.other.id, type: "references")

        #expect(fake.writes.map(\.id) == [created.id, try await copy.queue.all()[1].id, edited.id, edge.id])
        _ = try await copy.queue.drain()
        #expect(try await copy.queue.forgetAnswered() == 4)

        #expect(try await copy.queue.all().isEmpty)
        #expect(fake.writes.count == 4)
        #expect(fake.writes.allSatisfy { $0.verdict == .accepted })
        await copy.close()
    }

    @Test func clearingTheOwnTimeOfAnAnsweredCreateSendsTheCreationTime() async throws {
        let fake = Self.seeded()
        let copy = fake.copy
        let created = try await copy.items.create(
            Draft(type: "core.note", properties: ["body": "b"], occurredAt: "2026-01-02T03:04:05.000Z"))
        let id = try #require(created.itemId)
        _ = try await copy.queue.drain()
        let held = try #require(try await copy.items.get(id))

        let write = try #require(
            try await copy.items.update(id, Edit(properties: [:], baseVersion: held.version, clearOccurredAt: true)))

        #expect(write.body["occurred_at"] == .string(held.createdAt))
        let cleared = try #require(try await copy.items.get(id))
        #expect(cleared.occurredAt == held.createdAt)
        await copy.close()
    }

    @Test func theVerdictChooserAcceptsByDefaultAndReadsBackWhatWasSet() async throws {
        let fake = Self.seeded()
        let write = QueuedWrite(id: "w", kind: .addTag, idempotencyKey: "k", queuedAt: "")
        #expect(fake.verdict(write) == .accepted)

        fake.verdict = { _ in .dead }

        #expect(fake.verdict(write) == .dead)
        await fake.copy.close()
    }

    @Test func aDrainAcceptsEveryWriteByDefaultAndTellsEachAnswer() async throws {
        let fake = Self.seeded()
        let copy = fake.copy
        let created = try await copy.items.create(Draft(type: "core.note", properties: ["body": "b"]))
        let edited = try await copy.items.update(created.itemId ?? "", Edit(properties: ["title": "E"], baseVersion: 0))
        let heard = Heard(copy.changes())

        let report = try await copy.queue.drain()

        #expect(report.answered == 2 && report.held == 0 && report.undelivered == 0 && report.unsent == 0)
        #expect(report.verdicts.map(\.id) == [created.id, edited.id])
        #expect(report.verdicts.allSatisfy { $0.verdict == .accepted })
        let queue = try await copy.queue.all()
        #expect(queue.map(\.verdict) == [.accepted, .accepted])
        #expect(queue.allSatisfy { $0.answeredAt != nil && !$0.waiting })
        try await eventually("the answers were told") { heard.all.count == 3 }
        #expect(
            heard.all.map(\.origin) == [
                .answered(report.verdicts[0]), .answered(report.verdicts[1]), .refreshed(.drained),
            ])
        let again = try await copy.queue.drain()
        #expect(again.answered == 0 && again.verdicts.isEmpty)
        await copy.close()
    }

    @Test func anAnswerMovesTheRowToTheVersionTheServerGaveIt() async throws {
        let fake = Self.seeded()
        let copy = fake.copy
        let id = try #require(try await copy.items.create(Draft(type: "core.note", properties: ["body": "b"])).itemId)
        _ = try await copy.edges.create(from: id, to: Self.other.id, type: "references")
        _ = try await copy.items.update(id, Edit(properties: ["title": "A"], baseVersion: 0))
        #expect(try await copy.items.get(id)?.version == 0, "a create the server has not answered")

        _ = try await copy.queue.drain()

        #expect(try await copy.items.get(id)?.version == 2, "the create made version 1 and the edit the next")
        #expect(try await copy.edges.from(id).map(\.version) == [1])
        _ = try await copy.edges.update(Self.edge.id, EdgeEdit(["note": "x"], baseVersion: Self.edge.version))
        _ = try await copy.queue.drain()
        #expect(
            try await copy.edges.from(Self.note.id).first { $0.id == Self.edge.id }?.version == Self.edge.version + 1,
            "an accepted edge edit steps it")
        _ = try await copy.items.update(id, Edit(properties: ["title": "B"], baseVersion: 2))
        _ = try await copy.items.update(Self.note.id, Edit(properties: ["title": "C"], baseVersion: 4))
        _ = try await copy.tags.add("t", to: id)
        #expect(try await copy.items.get(id)?.version == 2, "an edit that waits leaves the version")
        fake.verdict = { $0.itemId == id ? .merged(fields: ["title"]) : .refused(Refusal(reason: "no")) }

        _ = try await copy.queue.drain()

        #expect(try await copy.items.get(id)?.version == 3, "a merged edit moves it on, and a tag leaves it")
        #expect(try await copy.items.get(Self.note.id)?.version == 4, "a refused edit leaves it")
        await copy.close()
    }

    @Test func theChosenVerdictAnswersEachWriteAndARefusalPutsTheRowBack() async throws {
        let fake = Self.seeded()
        let copy = fake.copy
        let refusal = Refusal(reason: "validation_error", fields: [FieldRefusal(field: "title", message: "too long")])
        fake.verdict = { write in
            switch write.kind {
            case .createItem: .refused(refusal)
            case .updateItem: .merged(fields: ["title"])
            default: .accepted
            }
        }
        let created = try await copy.items.create(Draft(type: "core.note", properties: ["body": "b"]))
        let id = try #require(created.itemId)
        let seeded = try await copy.items.update(Self.note.id, Edit(properties: ["title": "E"], baseVersion: 4))
        let tagged = try await copy.tags.add("t", to: Self.note.id)

        let report = try await copy.queue.drain()

        #expect(report.answered == 3 && report.unsent == 0)
        let queue = Dictionary(uniqueKeysWithValues: try await copy.queue.all().map { ($0.id, $0) })
        #expect(queue[created.id]?.verdict == .refused(refusal))
        #expect(queue[seeded.id]?.verdict == .merged(fields: ["title"]))
        #expect(queue[tagged.id]?.verdict == .accepted)
        #expect(try await copy.items.get(id) == nil, "a refused create left its row")
        #expect(try await copy.items.get(Self.note.id)?.title == "E", "a merged edit was put back")
        await copy.close()
    }

    @Test func aWriteBehindARefusedOneIsRefusedUnsentAndTheRefusedOneIsKeptUntilDiscarded() async throws {
        let fake = Self.seeded()
        let copy = fake.copy
        fake.verdict = { $0.kind == .createItem ? .refused(Refusal(reason: "forbidden")) : .accepted }
        let created = try await copy.items.create(Draft(type: "core.note", properties: ["body": "b"], tags: ["t"]))
        let seeded = try await copy.items.update(Self.note.id, Edit(properties: ["title": "E"], baseVersion: 4))

        let report = try await copy.queue.drain()

        #expect(report.answered == 2 && report.unsent == 1)
        let queue = try await copy.queue.all()
        let tag = try #require(queue.first { $0.kind == .addTag })
        guard case .refused(let refusal)? = tag.verdict else {
            Issue.record("the write behind a refused create was \(String(describing: tag.verdict))")
            return
        }
        #expect(refusal.reason == "the create_item it waits for was refused")
        #expect(try await copy.items.get(created.itemId ?? "") == nil)
        #expect(try await copy.items.get(Self.note.id)?.title == "E")
        #expect(queue.first { $0.id == seeded.id }?.verdict == .accepted)
        #expect(try await copy.queue.forgetAnswered() == 1, "only the accepted edit is forgotten")
        #expect(try await copy.queue.discard(tag.id) == true)
        #expect(try await copy.queue.discard(created.id) == true)
        #expect(try await copy.queue.all().isEmpty)
        #expect(fake.writes.count == 3)
        await copy.close()
    }

    @Test func aWriteTheChooserLeavesUnansweredHoldsEverythingBehindIt() async throws {
        let fake = Self.seeded()
        let copy = fake.copy
        let lost = try await copy.items.update(Self.note.id, Edit(properties: ["title": "1"], baseVersion: 4))
        let behind = try await copy.items.update(Self.note.id, Edit(properties: ["title": "2"], baseVersion: 4))
        let apart = try await copy.items.update(Self.other.id, Edit(properties: ["title": "3"], baseVersion: 1))
        fake.verdict = { $0.id == lost.id ? nil : .accepted }

        let report = try await copy.queue.drain()

        #expect(report.undelivered == 1 && report.held == 1 && report.answered == 1)
        let queue = Dictionary(uniqueKeysWithValues: try await copy.queue.all().map { ($0.id, $0) })
        #expect(queue[lost.id]?.verdict == nil && queue[lost.id]?.waiting == false)
        #expect(queue[behind.id]?.verdict == nil && queue[behind.id]?.waiting == true)
        #expect(queue[apart.id]?.verdict == .accepted)

        fake.verdict = { _ in .accepted }
        let next = try await copy.queue.drain()
        #expect(next.answered == 2 && next.held == 0)
        #expect(try await copy.queue.all().allSatisfy { $0.verdict == .accepted && !$0.waiting })
        await copy.close()
    }

    @Test func aRefusedEditPutsTheRowBackAsItWasBeforeTheWriteAndASeededRowKeepsItsGivenState() async throws {
        let fake = Self.seeded()
        let copy = fake.copy
        fake.verdict = {
            [.updateItem, .createEdge, .updateEdge].contains($0.kind) ? .refused(Refusal(reason: "no")) : .accepted
        }
        let first = try await copy.items.update(Self.note.id, Edit(properties: ["title": "1"], baseVersion: 4))
        let tag = try await copy.tags.add("t", to: Self.note.id)
        let edge = try await copy.edges.create(from: Self.other.id, to: Self.note.id, type: "references")
        let move = try await copy.edges.update(Self.edge.id, EdgeEdit(["n": 2], baseVersion: 2))

        _ = try await copy.queue.drain()

        #expect(try await copy.items.get(Self.note.id)?.title == "Seed")
        #expect(try await copy.items.get(Self.note.id)?.tags == ["seed", "t"], "the accepted tag was put back")
        #expect(try await copy.edges.to(Self.note.id).isEmpty, "a refused edge stayed")
        #expect(try await copy.edges.from(Self.note.id) == [Self.edge], "a refused edge edit was not put back")
        #expect(fake.writes.map(\.id) == [first.id, tag.id, edge.id, move?.id])
        await copy.close()
    }

    @Test func aWriteBehindABlockedOneWaitsAndAWithdrawRefusesIt() async throws {
        let fake = Self.seeded()
        let copy = fake.copy
        fake.verdict = { $0.kind == .createItem ? .blocked(reason: .conflictUnresolved) : .accepted }
        let created = try await copy.items.create(Draft(type: "core.note", properties: ["body": "b"], tags: ["t"]))
        let id = try #require(created.itemId)

        let report = try await copy.queue.drain()

        #expect(report.answered == 1 && report.held == 1 && report.unsent == 0)
        let tag = try #require(try await copy.queue.all().first { $0.kind == .addTag })
        #expect(tag.verdict == nil && tag.waiting)
        #expect(try await copy.items.get(id) != nil, "a blocked write put its row back")

        #expect(try await copy.queue.withdraw(created.id) == true)

        let left = try await copy.queue.all()
        #expect(left.map(\.id) == [tag.id])
        guard case .refused(let refusal)? = left.first?.verdict else {
            Issue.record("the tag was \(String(describing: left.first?.verdict))")
            return
        }
        #expect(refusal.reason.contains(created.id))
        #expect(try await copy.items.get(id) == nil, "withdrawing left the row")
        #expect(try await copy.queue.withdraw(tag.id) == false)
        await copy.close()
    }

    @Test func aWriteOnlyOrderedBehindARefusedOneStillGoes() async throws {
        let fake = Self.seeded()
        let copy = fake.copy
        fake.verdict = { $0.kind == .updateItem ? .refused(Refusal(reason: "no")) : .accepted }
        _ = try await copy.items.update(Self.note.id, Edit(properties: ["title": "1"], baseVersion: 4))
        let tag = try await copy.tags.add("t", to: Self.note.id)

        let report = try await copy.queue.drain()

        #expect(report.answered == 2 && report.unsent == 0)
        #expect(try await copy.queue.all().first { $0.id == tag.id }?.verdict == .accepted)
        await copy.close()
    }

    @Test func aDeleteQueuedBehindItsOwnCreateIsRebasedAndSentWhenTheCreateIsTaken() async throws {
        let fake = Self.seeded()
        let copy = fake.copy
        let made = try #require(
            try await copy.items.create(Draft(type: "core.note", properties: ["body": "b"])).itemId)
        let write = try await copy.items.delete(made)
        #expect(write.baseVersion == 0)

        let report = try await copy.queue.drain()

        #expect(report.unsent == 0 && report.answered == 2)
        let sent = try #require(try await copy.queue.all().first { $0.id == write.id })
        #expect(
            sent.verdict == .accepted && sent.baseVersion == 1, "the delete is based on the version the create made")
        await copy.close()
    }

    @Test func aDeleteWithNoServerVersionIsRefusedUnsent() async throws {
        var unconfirmed = Self.other
        unconfirmed.version = 0
        let fake = WorkingCopy.fake(items: [unconfirmed], itemTypes: [Self.noteType])
        let copy = fake.copy
        let write = try await copy.items.delete(unconfirmed.id)

        let report = try await copy.queue.drain()

        #expect(report.unsent == 1 && report.answered == 0)
        guard case .refused(let refusal)? = try await copy.queue.all().first(where: { $0.id == write.id })?.verdict
        else {
            Issue.record("the delete was not refused")
            return
        }
        #expect(
            refusal.reason == "the delete has no confirmed server version to remove; read the item before deleting it")
        await copy.close()
    }

    @Test func twoDrainsNeverAnswerTheSameWriteTwice() async throws {
        let fake = Self.seeded()
        let copy = fake.copy
        _ = try await copy.tags.add("t", to: Self.note.id)
        let offered = Mutex(0)
        let release = DispatchSemaphore(value: 0)
        fake.verdict = { _ in
            let count = offered.withLock { count -> Int in
                count += 1
                return count
            }
            if count == 1 { release.wait() }
            return .accepted
        }
        let first = Task { try await copy.queue.drain() }
        try await eventually("the first drain offered the write") { offered.withLock { $0 } == 1 }
        let started = Mutex(false)
        let second = Task {
            started.withLock { $0 = true }
            return try await copy.queue.drain()
        }
        try await eventually("the second drain started") { started.withLock { $0 } }
        // The second drain must be held out, so there is nothing to wait for: stop at
        // the first sign it was not, and otherwise give it two seconds to show one.
        let deadline = Date.now.addingTimeInterval(2)
        while offered.withLock({ $0 }) == 1, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(offered.withLock { $0 } == 1, "a second drain offered the write while the first held it")

        release.signal()
        let reports = [try await first.value, try await second.value]

        #expect(reports.map(\.answered).reduce(0, +) == 1)
        #expect(offered.withLock { $0 } == 1)
        await copy.close()
    }

    @Test func aCanceledCallIsRefusedWithoutAStopFromTheRustCore() async throws {
        let copy = Self.seeded().copy
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await copy.queue.drain()
        }
        await #expect {
            try await task.value
        } throws: { error in
            if case MarfaError.canceled = error { true } else { false }
        }
        _ = try await copy.queue.drain()
        await copy.close()
    }

    @Test func anInputTheFakeCannotJudgeAsTheCoreDoesIsUnsupportedNotAnsweredDifferently() async throws {
        let copy = WorkingCopy.fake(
            itemTypes: [
                Self.noteType,
                ItemType(
                    id: "app.test.entry",
                    fields: [
                        TypeField(name: "count", type: "integer", declaredBy: "app.test.entry"),
                        TypeField(name: "site", type: "url", declaredBy: "app.test.entry"),
                        TypeField(
                            name: "code", type: "string", declaredBy: "app.test.entry",
                            definition: ["type": "string", "format": "bcp47"]),
                    ]),
            ]
        ).copy
        let held = try #require(
            try await copy.items.create(Draft(type: "core.note", properties: ["body": "b"])).itemId)
        let inputs: [(String, @Sendable () async throws -> Void)] = [
            (
                "items.create with links in a property",
                { _ = try await copy.items.create(Draft(type: "core.note", properties: ["body": "see [[x]]"])) }
            ),
            (
                "items.create with a integer field",
                { _ = try await copy.items.create(Draft(type: "app.test.entry", properties: ["count": "many"])) }
            ),
            (
                "items.create with a url field",
                { _ = try await copy.items.create(Draft(type: "app.test.entry", properties: ["site": "x"])) }
            ),
            (
                "items.create with a constrained code field",
                { _ = try await copy.items.create(Draft(type: "app.test.entry", properties: ["code": "en"])) }
            ),
            (
                "items.update with links in a property",
                { _ = try await copy.items.update(held, Edit(properties: ["body": "![[f]]"], baseVersion: 0)) }
            ),
            (
                "an occurredAt of the form yesterday",
                {
                    _ = try await copy.items.create(
                        Draft(type: "core.note", properties: ["body": "b"], occurredAt: "yesterday"))
                }
            ),
            (
                "a tag with surrounding whitespace",
                { _ = try await copy.tags.add(" x", to: "absent") }
            ),
        ]
        for (call, make) in inputs {
            await #expect(performing: { try await make() }, throws: refusedAsUnsupported(call))
        }
        #expect(try await copy.queue.all().count == 1)
        await copy.close()
    }

    @Test func forgettingNamedAnswersLeavesTheRest() async throws {
        let fake = Self.seeded()
        let copy = fake.copy
        let one = try await copy.tags.add("a", to: Self.note.id)
        let two = try await copy.tags.add("b", to: Self.note.id)
        _ = try await copy.queue.drain()

        #expect(try await copy.queue.forgetAnswered(ids: [two.id, "absent"]) == 1)
        #expect(try await copy.queue.all().map(\.id) == [one.id])
        #expect(try await copy.queue.forgetAnswered(ids: []) == 0)
        await copy.close()
    }

    @Test @MainActor func aViewModelTakesTheFakeThroughTheInitItTakesTheRealCopyBy() async throws {
        let fake = Self.seeded()
        let model = NotesModel(copy: fake.copy)

        await model.load()
        #expect(model.titles == ["Other", "Seed"])
        await model.add(title: "New")

        #expect(model.titles == ["New", "Other", "Seed"])
        #expect(fake.writes.map(\.kind) == [.createItem])
        #expect(fake.writes.first?.body["properties"]?.object?["title"] == "New")
        await fake.copy.close()
    }

    /// The refused write's own change goes back, and what was answered since stays.
    @Test func aRefusedWriteUndoesOnlyWhatItChangedSoLaterAcceptedWritesSurvive() async throws {
        let fake = Self.seeded()
        let copy = fake.copy
        let titleEdit = try await copy.items.update(Self.note.id, Edit(properties: ["title": "T"], baseVersion: 4))
        _ = try await copy.items.update(Self.note.id, Edit(properties: ["body": "B"], baseVersion: 4))
        let tag = try await copy.tags.add("refused", to: Self.note.id)
        _ = try await copy.tags.add("kept", to: Self.note.id)
        let edgeEdit = try await copy.edges.update(Self.edge.id, EdgeEdit(["n": 2], baseVersion: 2))
        _ = try await copy.edges.update(Self.edge.id, EdgeEdit(["m": 3], baseVersion: 2))
        let refused = Set([titleEdit.id, tag.id, try #require(edgeEdit).id])
        fake.verdict = { refused.contains($0.id) ? .refused(Refusal(reason: "no")) : .accepted }

        _ = try await copy.queue.drain()

        let note = try #require(try await copy.items.get(Self.note.id))
        #expect(note.title == "Seed" && note.body == "B")
        #expect(note.tags == ["kept", "seed"])
        #expect(try await copy.edges.from(Self.note.id).first?.properties == ["n": 1, "m": 3])
        await copy.close()
    }

    @Test func aCreateWhoseTagWriteIsRefusedKeepsTheItemWithoutTheTag() async throws {
        let fake = Self.seeded()
        let copy = fake.copy
        fake.verdict = { $0.kind == .addTag ? .refused(Refusal(reason: "no")) : .accepted }
        let created = try await copy.items.create(
            Draft(type: "core.note", properties: ["body": "b"], tags: ["refused"]))
        let id = try #require(created.itemId)

        _ = try await copy.queue.drain()

        #expect(try await copy.items.get(id)?.tags == [])
        await copy.close()
    }

    @Test func aFieldWithConstraintsBeyondItsKindIsUnsupportedWhateverTheValue() async throws {
        let copy = WorkingCopy.fake(
            itemTypes: [
                ItemType(
                    id: "app.test.entry",
                    fields: [
                        TypeField(
                            name: "few", type: "array", declaredBy: "app.test.entry",
                            definition: ["type": "array", "maxItems": 2]),
                        TypeField(
                            name: "pick", type: "string", declaredBy: "app.test.entry",
                            definition: ["type": "string", "enum": ["a", "b"]]),
                        TypeField(
                            name: "bare", type: "array", declaredBy: "app.test.entry", definition: ["type": "array"]),
                    ])
            ]
        ).copy
        for properties: JSONObject in [["few": [1, 2, 3]], ["few": [1]], ["pick": "a"], ["pick": "c"]] {
            await #expect {
                _ = try await copy.items.create(Draft(type: "app.test.entry", properties: properties))
            } throws: { error in
                guard case .unsupported(let call)? = error as? FakeCopyError else { return false }
                return call.contains("constrained")
            }
        }
        _ = try await copy.items.create(Draft(type: "app.test.entry", properties: ["bare": [1, 2, 3], "few": .null]))
        await copy.close()
    }

    @Test(
        arguments: [
            "2026-01-01T00:00:00.000+2460", "2026-01-01T00:00:00.000+0160", "2026-01-01T00:00:00.000+01:60",
            "2026-01-01T00:00:00.000+14:01", "2026-01-01T00:00:00.000+15:00", "2026-02-30",
            "2026-01-01T24:00:00Z", "2026-01-01T23:59:60Z", "2026-01-01T00:00:00.5Z", "2026-01-01T00:00:00,500Z",
            "2026-01-01 00:00:00", "bogus",
        ])
    func aTimeWhoseNormalizationWasNotCheckedAgainstTheCoreIsUnsupported(time: String) async throws {
        let copy = WorkingCopy.fake(itemTypes: [Self.noteType]).copy
        await #expect {
            _ = try await copy.items.create(Draft(type: "core.note", properties: ["body": "b"], occurredAt: time))
        } throws: { error in
            guard case .unsupported(let call)? = error as? FakeCopyError else { return false }
            return call.contains(time)
        }
        #expect(try await copy.queue.all().isEmpty)
        await copy.close()
    }

    @Test func aLinkInAnyPropertyOfAnyTypeIsUnsupported() async throws {
        let copy = WorkingCopy.fake(itemTypes: [ItemType(id: "app.review.note")]).copy
        for properties: JSONObject in [
            ["text": "see [[x]]"], ["list": ["![[file.png]]"]], ["deep": ["a": ["b": "[["]]],
        ] {
            await #expect {
                _ = try await copy.items.create(Draft(type: "app.review.note", properties: properties))
            } throws: { error in
                guard case .unsupported(let call)? = error as? FakeCopyError else { return false }
                return call.contains("links")
            }
        }
        #expect(try await copy.queue.all().isEmpty)
        await copy.close()
    }

    @Test func theRowsAreTheSeedPlusEveryWriteNotRefusedSoARefusedEarlierEditLeavesTheAcceptedLaterOne() async throws {
        let fake = Self.seeded()
        let copy = fake.copy
        let first = try await copy.items.update(Self.note.id, Edit(properties: ["title": "Refused"], baseVersion: 4))
        _ = try await copy.items.update(Self.note.id, Edit(properties: ["title": "Accepted"], baseVersion: 4))
        let firstTag = try await copy.tags.add("same", to: Self.note.id)
        _ = try await copy.tags.add("same", to: Self.note.id)
        fake.verdict = { [first.id, firstTag.id].contains($0.id) ? .refused(Refusal(reason: "no")) : .accepted }

        _ = try await copy.queue.drain()

        let note = try #require(try await copy.items.get(Self.note.id))
        #expect(note.title == "Accepted" && note.tags == ["same", "seed"])
        await copy.close()
    }

    @Test func aRefusedCreateOfAnExistingIDLeavesTheRowItDidNotMake() async throws {
        let fake = Self.seeded()
        let copy = fake.copy
        fake.verdict = { [.createItem, .createEdge].contains($0.kind) ? .refused(Refusal(reason: "no")) : .accepted }
        _ = try await copy.items.create(
            Draft(type: "core.note", properties: ["body": "other"], id: Self.note.id))
        _ = try await copy.edges.create(from: Self.note.id, to: Self.other.id, type: "references", id: Self.edge.id)

        _ = try await copy.queue.drain()

        #expect(try await copy.items.get(Self.note.id) == Self.note)
        #expect(try await copy.edges.from(Self.note.id) == [Self.edge])
        await copy.close()
    }

    @Test func aRefusedEditOfKeysThatDifferOnlyInNormalizationKeepsBothValues() async throws {
        let composed = "\u{e9}"
        let decomposed = "e\u{301}"
        var properties: JSONObject = ["body": "b"]
        properties[composed] = 1
        properties[decomposed] = 2
        let seed = Item(
            id: "01a1500d-78bd-73f0-8c55-2a4160c5ff09", type: "core.note", properties: properties, state: .active,
            tier: .library, version: 1, schemaVersion: 1, source: "app", sourceId: nil,
            occurredAt: "2026-09-26T00:00:00.000Z", createdAt: "2026-09-26T00:00:00.000Z",
            updatedAt: "2026-09-26T00:00:00.000Z", tags: [])
        let fake = WorkingCopy.fake(items: [seed], itemTypes: [Self.noteType])
        fake.verdict = { _ in .refused(Refusal(reason: "no")) }
        var edit = JSONObject()
        edit[composed] = 10
        edit[decomposed] = 20
        _ = try await fake.copy.items.update(seed.id, Edit(properties: edit, baseVersion: 1))
        #expect(try await fake.copy.items.get(seed.id)?.properties[decomposed] == 20)

        _ = try await fake.copy.queue.drain()

        let held = try #require(try await fake.copy.items.get(seed.id))
        #expect(held.properties[composed] == 1 && held.properties[decomposed] == 2)
        await fake.copy.close()
    }
}

/// A view model as an app writes it: it takes a `WorkingCopy`, so a test or a
/// preview hands it the fake and the app hands it the real one.
@MainActor @Observable
final class NotesModel {
    private let copy: WorkingCopy
    private(set) var titles: [String] = []

    init(copy: WorkingCopy) {
        self.copy = copy
    }

    func load() async {
        titles = (try? await copy.items.list(ListFilters(type: "core.note")))?.compactMap(\.title) ?? []
    }

    func add(title: String) async {
        _ = try? await copy.items.create(Draft(type: "core.note", properties: ["title": .string(title), "body": ""]))
        await load()
    }
}
#endif
