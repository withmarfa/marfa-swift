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
        let copy = try await Live.hydrated()
        let title = "Live \(UUID())"
        let created = try await copy.items.create(Live.note(title))
        let tagged = try await copy.tags.add("favorite", to: created.itemId ?? "")
        let report = try await copy.queue.drain()
        let verdicts = report.verdicts.filter { [created.id, tagged.id].contains($0.id) }.map(\.verdict)
        #expect(verdicts == [.accepted, .accepted])
        let found = try await copy.search(title, filters: SearchFilters(type: "core.note", tags: ["favorite"]))
        #expect(found.map(\.item.title) == [title])
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

    /// Each verdict a write can reach from a server that answered.
    @Test func eachVerdictArrivesTyped() async throws {
        let copy = try await Live.hydrated()
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

    @Test func aWriteUnderARefusedKeyIsBlocked() async throws {
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
        let blocked = try await unkeyed.tags.add("favorite", to: id)
        let report = try await unkeyed.queue.drain()
        #expect(report.verdicts.first { $0.id == blocked.id }?.verdict == .blocked(reason: .credentialRefused))
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
        await reader.close()
        #expect(watch.isCancelled)
        #expect(reader.feed.watchTask == nil)
    }

    /// The watch starts from where the store stood when `changes()` returned.
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
        await second.close()
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

    /// The core lets one stream at a time move the cursor, so a catch-up or
    /// a hydration stops the follow while it runs and starts it after.
    @Test func aCatchUpAndAHydrationRunWhileAStreamIsHeld() async throws {
        let copy = try await Live.hydrated()
        let heard = Heard(copy.changes())
        // Long enough for the follow to hold the stream.
        try await Task.sleep(for: .milliseconds(300))
        _ = try await copy.catchUp()
        _ = try await copy.hydrate(types: ["core.note", "core.file"], tier: .feed)

        let elsewhere = try await Live.hydrated()
        let made = try await elsewhere.items.create(Live.note("after the hydration"))
        _ = try await elsewhere.queue.drain()
        try await eventually("the follow started again and told the note", within: 20) {
            heard.all.contains { $0.itemId == made.itemId }
        }
        #expect(heard.stops.isEmpty, "\(heard.stops)")
        await copy.close()
    }

    @Test func closingLetsGoOfTheStore() async throws {
        let store = Live.store()
        try await { () async throws in
            let copy = try await Live.hydrated(store)
            let heard = Heard(copy.changes())
            try await Task.sleep(for: .milliseconds(300))
            await copy.close()
            withExtendedLifetime(heard) {}
        }()
        try await eventually("a new open of the store was its writer", within: 1) {
            try await WorkingCopy.open(store: store).handle == .writer
        }
    }
}

extension Server {
    func with(key: String) -> Server { Server(url: url, key: key) }
}
