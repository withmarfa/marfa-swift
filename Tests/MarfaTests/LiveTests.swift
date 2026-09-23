import Foundation
import Testing

@testable import Marfa

/// The server a live test runs against, named by `MARFA_API_URL` and `MARFA_API_KEY`.
///
/// Without them the live tests are skipped by name.
enum Live {
    static let server: Server? = {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["MARFA_API_URL"].flatMap(URL.init(string:)),
            let key = environment["MARFA_API_KEY"]
        else { return nil }
        return Server(url: url, key: key)
    }()

    static func store() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "marfa-live-\(UUID()).sqlite")
    }
}

/// Where the live tests are required, a missing server fails rather than
/// skipping them, so a run that lost its server cannot pass on the unit tests.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MARFA_LIVE_REQUIRED"] != nil))
func theLiveTestsHaveAServerWhereTheyAreRequired() {
    #expect(Live.server != nil, "MARFA_LIVE_REQUIRED is set, and MARFA_API_URL or MARFA_API_KEY is not")
}

@Suite(.enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"))
struct LiveServer {
    @Test func aWriteMadeHereIsAnsweredAndHeld() async throws {
        let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
        _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
        let title = "Live \(UUID())"
        let created = try await copy.items.create(
            Draft(type: "core.note", properties: ["title": .string(title), "body": "b"], tier: .feed))
        let tagged = try await copy.tags.add("favorite", to: created.itemId ?? "")
        let report = try await copy.queue.drain()
        let verdicts = report.verdicts.filter { [created.id, tagged.id].contains($0.id) }.map(\.verdict)
        #expect(verdicts == [.accepted, .accepted])
        let found = try await copy.search(title, filters: SearchFilters(type: "core.note", tags: ["favorite"]))
        #expect(found.map(\.item.title) == [title])
    }

    @Test func attachedBytesAreFetchedByAStoreThatNeverHeldThem() async throws {
        let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
        _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
        let note = try await copy.items.create(
            Draft(type: "core.note", properties: ["title": "with a file", "body": "b"], tier: .feed))
        let file = FileManager.default.temporaryDirectory.appending(path: "marfa-live-\(UUID()).txt")
        let bytes = Data("bytes \(UUID())\n".utf8)
        try bytes.write(to: file)
        let attached = try await copy.items.attach(to: note.itemId ?? "", file: file)
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
        #expect(try Data(contentsOf: fetched) == bytes)
        #expect(try await fresh.blobs.isHeld(hash))
    }

    /// Each verdict a write can reach from a server that answered.
    @Test func eachVerdictArrivesTyped() async throws {
        let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
        _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
        let titled = try await copy.items.create(
            Draft(type: "core.note", properties: ["title": "first", "body": "first"], tier: .feed))
        let bodied = try await copy.items.create(
            Draft(type: "core.note", properties: ["title": "other", "body": "first"], tier: .feed))
        let refused = try await copy.items.create(
            Draft(type: "system.device", properties: ["name": "not a device's to write"]))
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
        let elsewhere = try await WorkingCopy.open(store: Live.store(), server: Live.server)
        _ = try await elsewhere.hydrate(types: ["core.note"], tier: .feed)
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

    @Test func aWriteUnderARefusedKeyIsBlocked() async throws {
        let store = Live.store()
        // Hydrated under the good key by a copy that is gone before the
        // store opens again, so the second open is the writer.
        let id = try await { () async throws -> String in
            let copy = try await WorkingCopy.open(store: store, server: Live.server)
            _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
            let note = try await copy.items.create(
                Draft(type: "core.note", properties: ["title": "keyed", "body": "b"], tier: .feed))
            _ = try await copy.queue.drain()
            return try #require(note.itemId)
        }()
        let refusedKey = try #require(Live.server).with(key: "mk_not_a_key")
        let unkeyed = try await WorkingCopy.open(store: store, server: refusedKey)
        #expect(unkeyed.handle == .writer)
        let blocked = try await unkeyed.tags.add("favorite", to: id)
        let report = try await unkeyed.queue.drain()
        #expect(report.verdicts.first { $0.id == blocked.id }?.verdict == .blocked(reason: .credentialRefused))
    }

    /// A reader of a store the writer saves to is told each save.
    @Test func aReaderIsToldTheWriterSaved() async throws {
        let store = Live.store()
        let writer = try await WorkingCopy.open(store: store, server: Live.server)
        _ = try await writer.hydrate(types: ["core.note"], tier: .feed)
        let reader = try await WorkingCopy.openReader(store: store)
        var saves = reader.changes().makeAsyncIterator()
        try await eventually("the reader started watching") { reader.feed.isRunning }
        _ = try await writer.items.create(
            Draft(type: "core.note", properties: ["title": "saved", "body": "b"], tier: .feed))
        guard case .saved = await saves.next()?.origin else {
            Issue.record("the reader was not told the writer saved")
            return
        }
        reader.close()
        try await eventually("the watch stopped") { !reader.feed.isRunning }
    }

    @Test func aChangeMadeElsewhereArrivesOnTheStream() async throws {
        let watching = try await WorkingCopy.open(store: Live.store(), server: Live.server)
        _ = try await watching.hydrate(types: ["core.note"], tier: .feed)
        let elsewhere = try await WorkingCopy.open(store: Live.store(), server: Live.server)
        _ = try await elsewhere.hydrate(types: ["core.note"], tier: .feed)

        // Made before the watch starts and sent after it, so the event
        // waited for is this one and not another test's running beside it.
        let made = try await elsewhere.items.create(
            Draft(type: "core.note", properties: ["title": "from elsewhere", "body": "b"], tier: .feed))
        let arrived = Task { () -> Change? in
            for await change in watching.changes() {
                if case .server(event: "item.created", _) = change.origin, change.itemId == made.itemId {
                    return change
                }
            }
            return nil
        }
        try await Task.sleep(for: .seconds(1))
        _ = try await elsewhere.queue.drain()
        let deadline = Task {
            try await Task.sleep(for: .seconds(20))
            arrived.cancel()
        }
        let change = await arrived.value
        deadline.cancel()
        #expect(change?.itemId == made.itemId)
        let held = try await watching.items.get(made.itemId ?? "")
        #expect(held?.title == "from elsewhere")
        // The last stream let go stops the event stream it shared.
        try await eventually("the follow stopped once no stream held it") { !watching.feed.isRunning }
    }
}

extension Server {
    func with(key: String) -> Server { Server(url: url, key: key) }
}
