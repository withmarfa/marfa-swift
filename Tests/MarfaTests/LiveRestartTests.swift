import Foundation
import Testing

@testable import Marfa

@Test(.enabled(if: ProcessInfo.processInfo.environment["MARFA_LIVE_REQUIRED"] != nil))
func theRestartTestsHaveACheckoutWhereTheLiveTestsAreRequired() {
    #expect(OwnServer.monorepo != nil, "MARFA_LIVE_REQUIRED is set, and MARFA_MONOREPO is not")
}

/// Each test stops and starts a server of its own under a copy, so none of
/// them can take the shared live server away from the other suites.
@Suite(
    .serialized,
    .enabled(if: OwnServer.monorepo != nil, "set MARFA_MONOREPO to a marfa checkout whose server is built"),
    .timeLimit(.minutes(5)))
struct LiveRestart {
    static func hydrated(_ own: OwnServer) async throws -> WorkingCopy {
        let copy = try await WorkingCopy.open(store: Live.store(), server: own.server)
        _ = try await copy.hydrate(types: ["core.note"], tier: .library)
        return copy
    }

    static func note(_ title: String) -> Draft {
        Draft(type: "core.note", properties: ["title": .string(title), "body": "b", "notes": "n"], tier: .library)
    }

    /// What the server holds, read past the copy.
    static func read(_ own: OwnServer, _ id: String) async throws -> (status: Int, item: JSONObject?) {
        var request = URLRequest(url: own.url.appending(path: "items/\(id)"))
        request.setValue("Bearer \(own.key)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return (status, nil) }
        return (status, try JSONObject(json: String(decoding: body, as: UTF8.self))["item"]?.object)
    }

    @Test func theFollowSaysWhenTheServerGoesAndComesBackAndADrainThenSends() async throws {
        let own = try await OwnServer.boot()
        do {
            let copy = try await Self.hydrated(own)
            let made = try await copy.items.create(Self.note("before the server went"))
            #expect(try await copy.queue.drain().verdicts.map(\.verdict) == [.accepted])
            let heard = Heard(copy.changes())
            // Long enough for the follow to hold its stream, so that it says
            // nothing until the server goes.
            try await Task.sleep(for: .milliseconds(500))
            #expect(!heard.all.contains { if case .serverReachable = $0.origin { true } else { false } })

            try await own.stop()
            try await eventually("the follow said the server went", within: 30) {
                heard.all.contains { if case .serverUnreachable = $0.origin { true } else { false } }
            }
            let unreachable = heard.all.compactMap { change -> MarfaError? in
                if case .serverUnreachable(let why) = change.origin { why } else { nil }
            }
            #expect(unreachable.count == 1)
            if case .network = unreachable.first {
            } else {
                Issue.record("a stopped server was told as \(String(describing: unreachable.first))")
            }

            // Saved and queued while the server is away; a drain cannot send it.
            let id = try #require(made.itemId)
            let held = try #require(try await copy.items.get(id))
            _ = try await copy.items.update(id, Edit(.merge(["title": "while away"]), baseVersion: held.version))
            let away = try await copy.queue.drain()
            #expect(away.undelivered == 1)
            #expect(away.verdicts.isEmpty)

            try await own.start()
            try await eventually("the follow said the server came back", within: 60) {
                heard.all.contains { if case .serverReachable = $0.origin { true } else { false } }
            }
            #expect(heard.all.filter { if case .serverUnreachable = $0.origin { true } else { false } }.count == 1)
            #expect(heard.all.filter { if case .serverReachable = $0.origin { true } else { false } }.count == 1)
            #expect(heard.stops.isEmpty)
            #expect(try await copy.queue.drain().verdicts.map(\.verdict) == [.accepted])
            #expect(try await Self.read(own, id).item?["properties"]?.object?["title"] == "while away")
            heard.stop()
            await copy.close()
        } catch {
            try? await own.end()
            throw error
        }
        try await own.end()
    }

    @Test func editsThatReplaceRetypeAndMoveTierQueueOfflineAndLandOnceBack() async throws {
        let own = try await OwnServer.boot()
        do {
            let copy = try await Self.hydrated(own)
            let whole = try #require(try await copy.items.create(Self.note("sent whole")).itemId)
            let moved = try #require(try await copy.items.create(Self.note("moved")).itemId)
            let pinned = try #require(try await copy.items.create(Self.note("moved, and pinned")).itemId)
            #expect(try await copy.queue.drain().verdicts.count == 3)
            _ = try await copy.pin(pinned)

            try await own.stop()
            let wholeRead = try #require(try await copy.items.get(whole))
            _ = try await copy.items.update(
                whole, Edit(.replace(["body": "only this"]), baseVersion: wholeRead.version))
            #expect(try await copy.items.get(whole)?.properties == ["body": "only this"])
            let movedRead = try #require(try await copy.items.get(moved))
            _ = try await copy.items.update(
                moved, Edit(.merge(["status": "open"]), baseVersion: movedRead.version, type: "core.task"))
            let pinnedRead = try #require(try await copy.items.get(pinned))
            _ = try await copy.items.update(pinned, Edit(baseVersion: pinnedRead.version, tier: .feed))
            // Shown before it is sent.
            #expect(try await copy.items.get(moved)?.type == "core.task")
            #expect(try await copy.items.get(pinned)?.tier == .feed)
            let away = try await copy.queue.drain()
            #expect(away.undelivered == 3)
            #expect(away.verdicts.isEmpty)

            try await own.start()
            // The retype expires the copy once answered
            // (`device/view-changed`), so the drain may end there with every
            // write answered.
            do {
                _ = try await copy.queue.drain()
            } catch MarfaError.copyExpired(reason: "read_view_changed", _) {
                _ = try await copy.hydrate(types: ["core.note"], tier: .library)
                _ = try await copy.queue.drain()
            }
            #expect(
                try await copy.queue.all().map(\.verdict) == [
                    .accepted, .accepted, .accepted, .accepted, .accepted, .accepted,
                ])
            #expect(try await Self.read(own, whole).item?["properties"] == .object(["body": "only this"]))
            let movedThere = try #require(try await Self.read(own, moved).item)
            #expect(movedThere["type"] == "core.task")
            #expect(movedThere["properties"]?.object?["status"] == "open")
            #expect(try await Self.read(own, pinned).item?["tier"] == "feed")
            // A move out of the slice lets an unpinned row go once answered,
            // and keeps a pinned one.
            #expect(try await copy.items.get(moved) == nil)
            #expect(try await copy.items.get(pinned)?.tier == .feed)
            await copy.close()
        } catch {
            try? await own.end()
            throw error
        }
        try await own.end()
    }

    @Test func aPurgeAndTheBinAreRefusedOfflineAndChangeNothing() async throws {
        let own = try await OwnServer.boot()
        do {
            let copy = try await Self.hydrated(own)
            let id = try #require(try await copy.items.create(Self.note("trashed, then purged offline")).itemId)
            _ = try await copy.queue.drain()
            // Trashed elsewhere, so the copy holds it in the bin with nothing
            // waiting, which a purge needs.
            var trash = URLRequest(url: own.url.appending(path: "items/\(id)"))
            trash.httpMethod = "DELETE"
            trash.setValue("Bearer \(own.key)", forHTTPHeaderField: "Authorization")
            _ = try await URLSession.shared.data(for: trash)
            _ = try await copy.catchUp()
            #expect(
                try await copy.items.list(ListFilters(state: .trashed)).contains { $0.id == id },
                "the copy did not hold the trashed item")
            try await own.stop()
            let queued = try await copy.queue.all().count
            await #expect {
                try await copy.items.purge(id)
            } throws: { error in
                if case MarfaError.network = error { true } else { false }
            }
            #expect(try await copy.items.list(ListFilters(state: .trashed)).contains { $0.id == id })
            #expect(try await copy.queue.all().count == queued)
            await #expect {
                _ = try await copy.items.bin()
            } throws: { error in
                if case MarfaError.network = error { true } else { false }
            }
            try await own.start()
            await copy.close()
        } catch {
            try? await own.end()
            throw error
        }
        try await own.end()
    }
}
