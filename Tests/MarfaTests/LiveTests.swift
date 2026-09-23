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
        let report = try await copy.queue.drain()
        #expect(report.verdicts.allSatisfy { $0.verdict == .accepted })
        let hash = try #require(attached.upload.blob)

        let fresh = try await WorkingCopy.open(store: Live.store(), server: Live.server)
        #expect(try await !fresh.blobs.isHeld(hash))
        let fetched = try await fresh.blobs.get(hash)
        #expect(try Data(contentsOf: fetched) == bytes)
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
    }
}
