import Foundation
import SQLite3
import Testing

@testable import Marfa

/// The server a live test runs against, named by `MARFA_API_URL` and `MARFA_API_KEY`.
///
/// Without them the live tests are skipped by name.
enum Live {
    /// The environment's server, or why the address it names is none.
    static let named = Result { try Server.fromEnvironment() }
    static var server: Server? { try? named.get() }

    static func store() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "marfa-live-\(UUID()).sqlite")
    }

    /// Writes a dead write into a store's queue, and answers its id.
    ///
    /// The row is as the ceiling leaves one, but for its reason column, which
    /// names `reason` where no dead row the core writes carries one: a release
    /// reading the reason without the verdict would take it. That is why the
    /// row is written here rather than drained into being.
    static func deadWrite(in store: URL, reason: String) throws -> String {
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        let id = UUID().uuidString.lowercased()
        let insert = """
            INSERT INTO queue (id, kind, idempotency_key, payload, verdict, reason, refusals, sent,
                               queued_at, answered_at)
            VALUES (?1, 'update_item', ?1, '{}', 'dead', ?2, 5, 1,
                    '2026-01-01T00:00:00Z', '2026-01-01T00:00:01Z')
            """
        var statement: OpaquePointer?
        try #require(
            sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK,
            "\(String(cString: sqlite3_errmsg(db)))")
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id, -1, transient)
        sqlite3_bind_text(statement, 2, reason, -1, transient)
        try #require(sqlite3_step(statement) == SQLITE_DONE, "\(String(cString: sqlite3_errmsg(db)))")
        return id
    }

    /// Marks a queued write as sent and blocked for `reason`, as the drain
    /// leaves a write the server refused that way.
    ///
    /// Neither reason can be had on cue through the package: one needs a
    /// server that prunes versions, the other a retype, which `Edit` cannot
    /// send.
    static func block(_ id: String, in store: URL, reason: String) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        let update = """
            UPDATE queue SET verdict = 'blocked', reason = ?2, refusals = 1, sent = 1,
                             answered_at = '2026-01-01T00:00:01Z'
            WHERE id = ?1
            """
        var statement: OpaquePointer?
        try #require(
            sqlite3_prepare_v2(db, update, -1, &statement, nil) == SQLITE_OK,
            "\(String(cString: sqlite3_errmsg(db)))")
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id, -1, transient)
        sqlite3_bind_text(statement, 2, reason, -1, transient)
        try #require(sqlite3_step(statement) == SQLITE_DONE, "\(String(cString: sqlite3_errmsg(db)))")
        try #require(sqlite3_changes(db) == 1, "no queued write \(id)")
    }

    /// The reason column of one queued write, as the store holds it.
    static func reasonColumn(of id: String, in store: URL) throws -> String? {
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        var statement: OpaquePointer?
        try #require(
            sqlite3_prepare_v2(db, "SELECT reason FROM queue WHERE id = ?1", -1, &statement, nil) == SQLITE_OK,
            "\(String(cString: sqlite3_errmsg(db)))")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        try #require(sqlite3_step(statement) == SQLITE_ROW, "no queued write \(id)")
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    static func file(_ text: String, named name: String = "marfa-live-\(UUID()).txt") throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: name)
        try Data(text.utf8).write(to: file)
        return file
    }

    /// A working copy of every note at `feed`.
    static func hydrated(_ store: URL = store()) async throws -> WorkingCopy {
        let copy = try await WorkingCopy.open(store: store, server: server)
        _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
        return copy
    }

    static func note(_ title: String, tags: [String] = [], occurredAt: String? = nil) -> Draft {
        Draft(
            type: "core.note", properties: ["title": .string(title), "body": "b"], tags: tags, tier: .feed,
            occurredAt: occurredAt)
    }

    /// Registers a type on the server, which the working copy has no door for.
    static func register(_ type: [String: Any]) async throws {
        guard let server else {
            Issue.record("no server to register a type on")
            return
        }
        var request = URLRequest(url: server.url.appending(path: "types"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(server.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: type)
        let (body, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        #expect(status == 201, "registering a type answered \(status ?? 0): \(String(decoding: body, as: UTF8.self))")
    }
}

/// Where the live tests are required, a missing server fails rather than
/// skipping them, so a run that lost its server cannot pass on the unit tests.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MARFA_LIVE_REQUIRED"] != nil), .timeLimit(.minutes(1)))
func theLiveTestsHaveAServerWhereTheyAreRequired() {
    #expect(throws: Never.self) { try Live.named.get() }
    #expect(Live.server != nil, "MARFA_LIVE_REQUIRED is set, and MARFA_API_URL or MARFA_API_KEY is not")
}

@Suite(
    .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
    .timeLimit(.minutes(2)))
struct LiveServer {
    @Test func aWriteMadeHereIsAnsweredAndHeld() async throws {
        let copy = try await Live.hydrated()
        let title = "Live \(UUID())"
        let created = try await copy.items.create(Live.note(title))
        let tagged = try await copy.tags.add("favorite", to: created.itemId ?? "")
        // A twin with the same title and no tag, which only the tag keeps out.
        let twin = try await copy.items.create(Live.note(title))
        let report = try await copy.queue.drain()
        let verdicts = report.verdicts.filter { [created.id, tagged.id, twin.id].contains($0.id) }.map(\.verdict)
        #expect(verdicts == [.accepted, .accepted, .accepted])
        let both = try await copy.search(title, filters: SearchFilters(type: "core.note"))
        #expect(both.count == 2)
        let found = try await copy.search(title, filters: SearchFilters(type: "core.note", tags: ["favorite"]))
        #expect(found.map(\.item.id) == [created.itemId])
    }

    /// A thumbnail written through the copy is read back from the held row,
    /// and an item of the same type that carries none has none: the witness
    /// that the first answer is the row's own.
    @Test func aThumbnailIsReadFromTheHeldRow() async throws {
        let type = "user.snapshot\(UUID().uuidString.prefix(8).lowercased())"
        try await Live.register([
            "id": type, "fields": ["title": ["type": "string"], "thumbnail": ["type": "thumbnail"]],
        ])
        let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
        _ = try await copy.hydrate(types: [type], tier: .feed)
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("snapshot".utf8)
        let with = try await copy.items.create(
            Draft(
                type: type,
                properties: [
                    "title": "With an image",
                    "thumbnail": .string("data:image/png;base64,\(bytes.base64EncodedString())"),
                ], tier: .feed))
        let without = try await copy.items.create(Draft(type: type, properties: ["title": "Without"], tier: .feed))
        let report = try await copy.queue.drain()
        let verdicts = report.verdicts.filter { [with.id, without.id].contains($0.id) }.map(\.verdict)
        #expect(verdicts == [.accepted, .accepted])
        let withId = try #require(with.itemId)
        let withoutId = try #require(without.itemId)
        let thumbnail = try #require(try await copy.items.thumbnail(withId))
        #expect(thumbnail.mimeType == "image/png")
        #expect(thumbnail.bytes == bytes)
        #expect(try await copy.items.thumbnail(withoutId) == nil)
    }

    @Test func attachedBytesAreFetchedByAStoreThatNeverHeldThem() async throws {
        let copy = try await Live.hydrated()
        let note = try await copy.items.create(Live.note("with a file"))
        let text = "bytes \(UUID())\n"
        let attached = try await copy.items.attach(to: note.itemId ?? "", file: try Live.file(text))
        let hash = try #require(attached.upload.blob)
        #expect(try await copy.blobs.isHeld(hash))
        let report = try await copy.queue.drain()
        let answered = Dictionary(report.verdicts.map { ($0.id, $0.verdict) }, uniquingKeysWith: { first, _ in first })
        for write in [note, attached.upload, attached.item, attached.edge] {
            #expect(
                answered[write.id] == .accepted, "\(write.kind) was answered \(String(describing: answered[write.id]))")
        }

        let fresh = try await WorkingCopy.open(store: Live.store(), server: Live.server)
        #expect(try await !fresh.blobs.isHeld(hash))
        let fetched = try await fresh.blobs.get(hash)
        #expect(try Data(contentsOf: fetched) == Data(text.utf8))
        #expect(try await fresh.blobs.isHeld(hash))
    }

    /// The four verdicts a server's answer settles a write with here:
    /// `accepted`, `refused`, `merged` and `conflicted`. `blocked` has a test
    /// of its own below, and `dead` is not reached.
    @Test func eachVerdictArrivesTyped() async throws {
        let copy = try await Live.hydrated()
        let titled = try await copy.items.create(
            Draft(type: "core.note", properties: ["title": "first", "body": "first"], tier: .feed))
        let bodied = try await copy.items.create(
            Draft(type: "core.note", properties: ["title": "other", "body": "first"], tier: .feed))
        let refused = try await copy.items.create(
            Draft(type: "system.connection", properties: ["name": "not a connection's to write"]))
        var report = try await copy.queue.drain()
        #expect(report.verdicts.first { $0.id == titled.id }?.verdict == .accepted)
        #expect(report.verdicts.first { $0.id == refused.id }?.verdict == .refused(reason: "type_not_permitted"))
        let titledId = try #require(titled.itemId)
        let bodiedId = try #require(bodied.itemId)

        // A second copy reads both notes at version 1, and this one moves
        // each to 2. The second copy's edits meet version 2: `title` takes
        // the last writer, and `body` keeps both copies. Two notes, because
        // two edits to one note wait on each other and the second is sent
        // on the first's answer.
        let elsewhere = try await Live.hydrated()
        _ = try await copy.items.update(titledId, Edit(properties: ["title": "second"], baseVersion: 1))
        _ = try await copy.items.update(bodiedId, Edit(properties: ["body": "second"], baseVersion: 1))
        report = try await copy.queue.drain()
        let merged = try await elsewhere.items.update(titledId, Edit(properties: ["title": "third"], baseVersion: 1))
        let conflicted = try await elsewhere.items.update(
            bodiedId, Edit(properties: ["body": "elsewhere"], baseVersion: 1))
        report = try await elsewhere.queue.drain()
        #expect(report.verdicts.first { $0.id == merged.id }?.verdict == .merged(fields: ["title"]))
        guard case .conflicted(_, let fields) = report.verdicts.first(where: { $0.id == conflicted.id })?.verdict
        else {
            Issue.record("the stale body edit was not conflicted: \(report.verdicts)")
            return
        }
        #expect(fields == ["body"])
    }

    /// An edit said to be read from an earlier version is merged, not taken.
    ///
    /// An editor holding a note while its copy catches up another copy's
    /// retitle saves the body its person changed, on the version it read.
    /// Said to be read, the retitle stands and the body lands; unsaid, the
    /// core refuses an older version. The editor's next save goes on the
    /// version the copy holds, and is taken on the first one's answer.
    @Test func anEditBasedOnAnEarlierReadIsMerged() async throws {
        let copy = try await Live.hydrated()
        let note = try await copy.items.create(Live.note("read here"))
        _ = try await copy.queue.drain()
        let id = try #require(note.itemId)
        let read = try #require(try await copy.items.get(id))

        let elsewhere = try await Live.hydrated()
        _ = try await elsewhere.items.update(
            id, Edit(properties: ["title": "retitled elsewhere"], baseVersion: read.version))
        _ = try await elsewhere.queue.drain()
        _ = try await copy.catchUp()
        let held = try #require(try await copy.items.get(id))
        #expect(held.version > read.version, "the copy did not take in the retitle")

        let edit = Edit(properties: ["body": "written here"], baseVersion: read.version)
        await #expect {
            _ = try await copy.items.update(id, edit)
        } throws: { error in
            guard case Marfa.MarfaError.invalid(let message) = error else { return false }
            return message.contains("based on version \(read.version)")
        }
        let saved = try await copy.items.updateAsRead(id, edit)
        let next = try await copy.items.update(
            id, Edit(properties: ["body": "written here, then more"], baseVersion: held.version))
        let report = try await copy.queue.drain()
        // Nothing collided, so the server applies the body over the retitle
        // and answers it as taken; `merged` names a collision it resolved.
        #expect(report.verdicts.first { $0.id == saved.id }?.verdict == .accepted)
        #expect(report.verdicts.first { $0.id == next.id }?.verdict == .accepted)
        let answered = try #require(try await copy.items.get(id))
        #expect(answered.properties["title"] == "retitled elsewhere")
        #expect(answered.properties["body"] == "written here, then more")
    }

    /// A refused key parks every write, and a release sends a write again:
    /// one by id, or every write blocked for a reason, which never takes a
    /// dead one.
    @Test func writesUnderARefusedKeyAreBlockedAndReleased() async throws {
        let store = Live.store()
        // Hydrated under the good key by a copy that is gone before the
        // store opens again, so the second open is the writer.
        let id = try await { () async throws -> String in
            let copy = try await Live.hydrated(store)
            let note = try await copy.items.create(Live.note("keyed"))
            _ = try await copy.queue.drain()
            return try #require(note.itemId)
        }()
        let refusedKey = try #require(Live.server).with(key: "mk_not_a_key")
        let unkeyed = try await WorkingCopy.open(store: store, server: refusedKey)
        #expect(unkeyed.handle == .writer)
        let first = try await unkeyed.tags.add("favorite", to: id)
        let second = try await unkeyed.tags.add("pinned", to: id)
        _ = try await unkeyed.queue.drain()
        func verdict(_ write: QueuedWrite) async throws -> Verdict? {
            try await unkeyed.queue.all().first { $0.id == write.id }?.verdict
        }
        #expect(try await verdict(first) == .blocked(reason: .credentialRefused))
        #expect(try await verdict(second) == .blocked(reason: .credentialRefused))
        // Beside them, a dead write whose reason column names the reason
        // released below, so a release reading the reason without the
        // verdict would take it.
        let dead = try Live.deadWrite(in: store, reason: "credential_refused")
        func deadRow() async throws -> QueuedWrite? {
            try await unkeyed.queue.all().first { $0.id == dead }
        }
        #expect(try await deadRow()?.verdict == .dead)
        // Spelled as the core spells the reason on a row it blocked, or the
        // seeded row names a reason no release reads and guards nothing.
        #expect(try Live.reasonColumn(of: dead, in: store) == Live.reasonColumn(of: second.id, in: store))
        let deadKey = try #require(try await deadRow()).idempotencyKey

        #expect(try await unkeyed.queue.release(first.id))
        #expect(try await verdict(first) == nil)
        #expect(try await verdict(second) == .blocked(reason: .credentialRefused))
        #expect(try await unkeyed.queue.release(reason: .keySpent) == 0)
        #expect(try await verdict(second) == .blocked(reason: .credentialRefused))
        #expect(try await unkeyed.queue.release(reason: .credentialRefused) == 1)
        #expect(try await verdict(second) == nil)
        #expect(try await deadRow()?.verdict == .dead, "a release by reason released a dead write")
        #expect(
            try await deadRow()?.idempotencyKey == deadKey,
            "a release by reason gave a dead write a fresh key, which is half a release")
        // The witness: the dead write is one a release takes, by its id, and
        // it is still queued afterwards, unanswered.
        #expect(try await unkeyed.queue.release(dead))
        let released = try #require(try await deadRow())
        #expect(released.verdict == nil)
    }

    /// A write that can never be sent is withdrawn, and the copy shows the
    /// note as the server holds it; any other write is not.
    @Test func aWriteThatCanNeverBeSentIsWithdrawn() async throws {
        for reason in ["ancestor_unavailable", "conflict_unresolved"] {
            let store = Live.store()
            let copy = try await Live.hydrated(store)
            let note = try await copy.items.create(Live.note("as the server holds it"))
            _ = try await copy.queue.drain()
            let id = try #require(note.itemId)
            let edit = try await copy.items.update(
                id,
                Edit(
                    properties: ["title": "never sent"], baseVersion: try #require(try await copy.items.get(id)).version
                ))
            let heard = Heard(copy.changes())
            let told = Change(origin: .refreshed(.withdrawn), itemId: nil, edgeId: nil)
            #expect(try await copy.queue.withdraw(edit.id) == false, "a write that may yet land was withdrawn")
            try Live.block(edit.id, in: store, reason: "key_spent")
            #expect(try await copy.queue.withdraw(edit.id) == false, "a write a release can send was withdrawn")
            try Live.block(edit.id, in: store, reason: reason)
            // The witness: a blocked write is laid over its row, so the copy
            // shows the edit until something takes it away.
            #expect(try await copy.items.get(id)?.properties["title"] == "never sent")
            #expect(!heard.all.contains(told), "a withdraw that took nothing was told")

            #expect(try await copy.queue.withdraw(edit.id), "a write blocked \(reason) was not withdrawn")
            #expect(try await copy.queue.all().contains { $0.id == edit.id } == false)
            #expect(try await copy.items.get(id)?.properties["title"] == "as the server holds it")
            try await eventually("the withdraw was told") { heard.all.contains(told) }
            await #expect {
                _ = try await copy.queue.withdraw("not-a-queued-write")
            } throws: { error in
                if case Marfa.MarfaError.notFound = error { true } else { false }
            }
            try await bounded("close") { await copy.close() }
        }
    }

    @Test func eachWriteIsToldOnceAsTheWriteItWas() async throws {
        let copy = try await Live.hydrated()
        let heard = Heard(copy.changes())
        var writes: [QueuedWrite] = []
        func record(_ write: QueuedWrite) -> QueuedWrite {
            writes.append(write)
            return write
        }
        let a = try #require(record(try await copy.items.create(Live.note("told a"))).itemId)
        let b = try #require(record(try await copy.items.create(Live.note("told b"))).itemId)
        let version = try #require(try await copy.items.get(a)).version
        _ = record(try await copy.items.update(a, Edit(properties: ["title": "told a, edited"], baseVersion: version)))
        _ = record(try await copy.tags.add("told", to: a))
        _ = record(try await copy.tags.remove("told", from: a))
        _ = record(try await copy.metadata.replaceTags(of: a, with: ["x"]))
        _ = record(try await copy.metadata.mergeTags(["y"], into: a))
        _ = record(try await copy.extensions.write("told", ["k": 1], on: a))
        _ = record(try await copy.extensions.delete("told", from: a))
        let edge = record(try await copy.edges.create(from: a, to: b, type: "references"))
        let edgeId = try #require(edge.edgeId)
        #expect(edge.targetId != edgeId)
        let edgeVersion = try #require(try await copy.edges.from(a).first).version
        _ = record(try await copy.edges.update(edgeId, properties: [:], baseVersion: edgeVersion))
        _ = record(try await copy.edges.delete(edgeId))
        _ = record(try await copy.items.transition(b, to: .archived))
        _ = record(try await copy.items.delete(b))
        _ = record(try await copy.items.restore(b))
        _ = record(try await copy.blobs.put(file: try Live.file("put \(UUID())")))
        let attached = try await copy.items.attach(to: a, file: try Live.file("attached \(UUID())"))
        writes += [attached.upload, attached.item, attached.edge]

        let expected = writes.map { Change(origin: .local($0.kind), itemId: $0.itemId, edgeId: $0.edgeId) }
        try await eventually("every write was told") { heard.locals.count >= expected.count }
        try await Task.sleep(for: .milliseconds(300))
        #expect(heard.locals == expected)
        try await bounded("close") { await copy.close() }
    }

    @Test func eachWriteDoesWhatItNames() async throws {
        let copy = try await Live.hydrated()
        let a = try #require(try await copy.items.create(Live.note("named a")).itemId)
        let b = try #require(try await copy.items.create(Live.note("named b")).itemId)
        func tags() async throws -> Set<String> { Set(try #require(try await copy.items.get(a)).tags) }

        _ = try await copy.tags.add("x", to: a)
        _ = try await copy.tags.add("y", to: a)
        #expect(try await tags() == ["x", "y"])
        _ = try await copy.tags.remove("x", from: a)
        #expect(try await tags() == ["y"])
        _ = try await copy.metadata.mergeTags(["z"], into: a)
        #expect(try await tags() == ["y", "z"])
        _ = try await copy.metadata.replaceTags(of: a, with: ["w"])
        #expect(try await tags() == ["w"])

        let wrote = try await copy.extensions.write("named", ["k": 1], on: a)
        #expect(wrote.kind == .writeExtension)
        let deleted = try await copy.extensions.delete("named", from: a)
        #expect(deleted.kind == .deleteExtension)
        #expect(deleted.namespace == "named")

        _ = try await copy.items.transition(a, to: .archived)
        #expect(try await copy.items.get(a)?.state == .archived)
        _ = try await copy.items.delete(b)
        #expect(try await copy.items.get(b) == nil)
        _ = try await copy.items.restore(b)
        #expect(try await copy.items.get(b)?.state == .active)

        let edgeId = UUID().uuidString.lowercased()
        let linked = try await copy.edges.create(from: a, to: b, type: "references", id: edgeId)
        #expect(linked.edgeId == edgeId)
        let from = try await copy.edges.from(a)
        #expect(from.map(\.id) == [edgeId])
        #expect(from.map(\.targetId) == [b])
        #expect(try await copy.edges.from(b).isEmpty)
        let to = try await copy.edges.to(b)
        #expect(to.map(\.id) == [edgeId])
        #expect(try await copy.edges.to(a).isEmpty)
        let ofType = try await copy.edges.ofType("references")
        #expect(ofType.contains { $0.id == edgeId }, "an edge still queued was left out of its type's read")
        #expect(ofType.allSatisfy { $0.edgeType == "references" })
        #expect(try await copy.edges.ofType("in-thread").contains { $0.id == edgeId } == false)
        // The core refuses an update based on a version it does not hold,
        // naming that version, which shows the base version reached it.
        let held = try #require(from.first).version
        await #expect {
            _ = try await copy.edges.update(edgeId, properties: [:], baseVersion: held + 7)
        } throws: { error in
            guard case Marfa.MarfaError.invalid(let message) = error else { return false }
            return message.contains("version \(held + 7)")
        }
        let updated = try await copy.edges.update(edgeId, properties: [:], baseVersion: held)
        #expect(updated.baseVersion == held)
    }

    @Test func anUploadAndAnAttachmentKeepWhatTheyWereGiven() async throws {
        let copy = try await Live.hydrated()
        let note = try #require(try await copy.items.create(Live.note("given")).itemId)

        let given = try await copy.blobs.put(file: try Live.file("given \(UUID())"), mimeType: "text/markdown")
        let guessed = try await copy.blobs.put(file: try Live.file("guessed \(UUID())"))
        _ = try await copy.queue.drain()
        let answered = try await copy.queue.all()
        func mimeType(_ write: QueuedWrite) throws -> JSONValue? {
            let row = try #require(answered.first { $0.id == write.id })
            #expect(row.verdict == .accepted)
            return try Properties.object(try #require(row.answer))["mime_type"]
        }
        #expect(try mimeType(given) == "text/markdown")
        // The witness: without one, the type is the file's extension's.
        #expect(try mimeType(guessed) == "text/plain")

        let attached = try await copy.items.attach(
            to: note, file: try Live.file("attached \(UUID())"), Attachment(mimeType: "text/csv", title: "Given title"))
        let fileId = try #require(attached.item.itemId)
        let file = try #require(try await copy.items.get(fileId))
        #expect(file.title == "Given title")
        #expect(file.properties["mime_type"] == "text/csv")
        // The witness: without one, the title is the file's name.
        let name = "plain-\(UUID()).txt"
        let plain = try await copy.items.attach(to: note, file: try Live.file("plain", named: name))
        let plainId = try #require(plain.item.itemId)
        let plainFile = try #require(try await copy.items.get(plainId))
        #expect(plainFile.title == name)
        #expect(plainFile.properties["mime_type"] == "text/plain")
    }

    @Test func searchAndListNarrowAsAsked() async throws {
        let copy = try await Live.hydrated()
        let word = "heron\(UUID().uuidString.prefix(8).lowercased())"
        let tag = "narrow-\(UUID())"
        var ids: [String] = []
        for day in 1...3 {
            let written = try await copy.items.create(
                Live.note("\(word) \(day)", tags: [tag], occurredAt: "2026-01-0\(day)T00:00:00.000Z"))
            ids.append(try #require(written.itemId))
        }
        #expect(try await copy.search(word).count == 3)
        #expect(try await copy.search(word, limit: 2).count == 2)

        let filters = ListFilters(type: "core.note", tags: [tag])
        let ascending = try await copy.items.list(filters, sort: Sort(field: .occurredAt, direction: .ascending))
        #expect(ascending.map(\.id) == ids)
        let descending = try await copy.items.list(filters, sort: Sort(field: .occurredAt, direction: .descending))
        #expect(descending.map(\.id) == ids.reversed())

        _ = try await copy.items.transition(ids[0], to: .archived)
        #expect(Set(try await copy.search(word).map(\.item.id)) == Set(ids[1...]))
        #expect(Set(try await copy.search(word, filters: SearchFilters(allStates: true)).map(\.item.id)) == Set(ids))
    }

    /// A reader of a store the writer saves to is told each save, once, and
    /// within a second, the first of them made as soon as it listened.
    @Test func aReaderIsToldEachSaveOnceAndWithinASecond() async throws {
        let store = Live.store()
        let writer = try await Live.hydrated(store)
        let reader = try await WorkingCopy.openReader(store: store)
        let heard = Heard(reader.changes())
        var made: [Date] = []
        for save in 1...3 {
            made.append(.now)
            _ = try await writer.items.create(Live.note("saved \(save)"))
            try await Task.sleep(for: .milliseconds(700))
        }
        try await Task.sleep(for: .seconds(1))
        let saves = heard.saves
        #expect(saves.count == 3, "\(heard.all)")
        for (madeAt, told) in zip(made, saves) {
            #expect(told.at.timeIntervalSince(madeAt) < 1, "a save was told \(told.at.timeIntervalSince(madeAt))s late")
        }

        let watch = try #require(reader.feed.watchTask)
        try await bounded("close") { await reader.close() }
        #expect(watch.isCancelled)
        #expect(reader.feed.watchTask == nil)
    }

    /// A save made as soon as a reader listens is told, each of five times.
    ///
    /// The watch's task starts on another thread at once, so against the
    /// core this rarely races a save; `Changes` holds the start to the
    /// version read before `changes()` returns.
    @Test func aSaveMadeAsSoonAsAReaderListensIsTold() async throws {
        let store = Live.store()
        let writer = try await Live.hydrated(store)
        let reader = try await WorkingCopy.openReader(store: store)
        for save in 1...5 {
            let heard = Heard(reader.changes())
            _ = try await writer.items.create(Live.note("at once \(save)"))
            try await eventually("save \(save) was told", within: 1) { !heard.saves.isEmpty }
            heard.stop()
            try await eventually("the stream was let go") { reader.feed.count == 0 }
        }
    }

    /// A second `open` of a store gets a reader, and watches the writer's
    /// saves as an `openReader` does, rather than following the server,
    /// which the core refuses a reader.
    @Test func aSecondOpenerIsToldTheWritersSaves() async throws {
        let store = Live.store()
        let writer = try await Live.hydrated(store)
        let second = try await WorkingCopy.open(store: store, server: Live.server)
        #expect(second.handle == .reader)
        let heard = Heard(second.changes())
        _ = try await writer.items.create(Live.note("seen by the second opener"))
        try await eventually("the second opener was told the writer saved") { !heard.saves.isEmpty }
        #expect(heard.stops.isEmpty)
        try await bounded("close") { await second.close() }
    }

    @Test func aChangeMadeElsewhereArrivesOnTheStream() async throws {
        let watching = try await Live.hydrated()
        let elsewhere = try await Live.hydrated()
        let made = try await elsewhere.items.create(Live.note("from elsewhere"))
        let other = try await elsewhere.items.create(Live.note("linked from elsewhere"))
        let linked = try await elsewhere.edges.create(
            from: try #require(made.itemId), to: try #require(other.itemId), type: "references")
        // The follow starts from the cursor the hydration stored, which is
        // before these were sent, so none is missed however long it takes to
        // connect.
        let heard = Heard(watching.changes())
        _ = try await elsewhere.queue.drain()

        func arrived(_ event: String, where matches: (Change) -> Bool) -> Change? {
            heard.all.first { change in
                guard case .server(event, _) = change.origin else { return false }
                return matches(change)
            }
        }
        try await eventually("the note and the edge arrived", within: 20) {
            arrived("item.created") { $0.itemId == made.itemId } != nil
                && arrived("edge.created") { $0.edgeId == linked.edgeId } != nil
        }
        guard case .server(_, let cursor) = arrived("item.created", where: { $0.itemId == made.itemId })?.origin
        else { return }
        #expect(Int(cursor) != nil, "the change carried the cursor \(cursor)")
        #expect(try await watching.items.get(made.itemId ?? "")?.title == "from elsewhere")

        // The last stream let go stops the follow, and the core has its
        // stream back for a catch-up of its own.
        heard.stop()
        try await eventually("the follow let go of the stream") {
            (try? await background { [core = watching.core] in try core.catchUp() }) != nil
        }
    }

    /// The core lets go of its stream only as a follow ends, a moment after
    /// it is stopped, so a stream taken in that moment waits for the end
    /// rather than being refused.
    @Test func aStreamTakenAsSoonAsTheLastIsLetGoIsFed() async throws {
        let watching = try await Live.hydrated()
        let first = Heard(watching.changes())
        // Long enough for the follow to hold the stream.
        try await Task.sleep(for: .milliseconds(300))
        first.stop()
        try await eventually("the first stream was let go") { watching.feed.count == 0 }
        let second = Heard(watching.changes())

        let elsewhere = try await Live.hydrated()
        let made = try await elsewhere.items.create(Live.note("after a stream was let go"))
        _ = try await elsewhere.queue.drain()
        try await eventually("the note arrived on the second stream", within: 20) {
            second.all.contains { $0.itemId == made.itemId }
        }
        #expect(second.stops.isEmpty, "\(second.stops)")
        try await bounded("close") { await watching.close() }
    }

    /// The core lets one stream at a time move the cursor, so a catch-up or
    /// a hydration stops the follow while it runs and starts it after.
    @Test func aCatchUpAndAHydrationRunWhileAStreamIsHeld() async throws {
        let copy = try await Live.hydrated()
        let heard = Heard(copy.changes())
        // Long enough for the follow to hold the stream.
        try await Task.sleep(for: .milliseconds(300))
        _ = try await bounded("the catch-up") { try await copy.catchUp() }
        _ = try await bounded("the hydration") {
            try await copy.hydrate(types: ["core.note", "core.file"], tier: .feed)
        }

        let elsewhere = try await Live.hydrated()
        let made = try await elsewhere.items.create(Live.note("after the hydration"))
        _ = try await elsewhere.queue.drain()
        try await eventually("the follow started again and told the note", within: 20) {
            heard.all.contains { $0.itemId == made.itemId }
        }
        #expect(heard.stops.isEmpty, "\(heard.stops)")
        try await bounded("close") { await copy.close() }
    }

    /// The follow's thread holds the store until the follow ends, so an
    /// open made as soon as `close()` returns is the writer only where
    /// `close()` waited for that end.
    @Test func closingLetsGoOfTheStore() async throws {
        for _ in 1...5 {
            let store = Live.store()
            try await { () async throws in
                let copy = try await Live.hydrated(store)
                let heard = Heard(copy.changes())
                // Long enough for the follow to hold the stream.
                try await Task.sleep(for: .milliseconds(300))
                try await bounded("close") { await copy.close() }
                withExtendedLifetime(heard) {}
            }()
            #expect(try await WorkingCopy.open(store: store).handle == .writer)
        }
    }
}

extension Server {
    func with(key: String) -> Server { Server(url: url, key: key) }
}
