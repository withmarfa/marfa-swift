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

    @Test func theFollowSaysWhenTheServerGoesAndComesBackAndDrainsWhatWaitedOnce() async throws {
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
            _ = try await copy.items.update(id, Edit(properties: ["title": "while away"], baseVersion: held.version))
            let away = try await copy.queue.drain()
            #expect(away.undelivered == 1)
            #expect(away.verdicts.isEmpty)

            try await own.start()
            try await eventually("the follow said the server came back", within: 60) {
                heard.all.contains { if case .serverReachable = $0.origin { true } else { false } }
            }
            #expect(heard.all.filter { if case .serverUnreachable = $0.origin { true } else { false } }.count == 1)
            #expect(heard.all.filter { if case .serverReachable = $0.origin { true } else { false } }.count == 1)
            // The app starts no drain: the held stream sends the write itself and says so.
            try await eventually("the follow said it drained what waited", within: 60) {
                heard.all.contains { if case .queueDrained = $0.origin { true } else { false } }
            }
            let drained = heard.all.compactMap { change -> DrainReport? in
                if case .queueDrained(let report) = change.origin { report } else { nil }
            }
            #expect(drained.count == 1)
            #expect(drained.first?.verdicts.map(\.verdict) == [.accepted])
            #expect(
                heard.all.contains {
                    if case .answered(let answer) = $0.origin { answer.verdict == .accepted } else { false }
                })
            #expect(heard.all.filter { if case .queueNotDrained = $0.origin { true } else { false } }.isEmpty)
            #expect(heard.stops.isEmpty)
            #expect(try await Self.read(own, id).item?["properties"]?.object?["title"] == "while away")
            // Sent once: nothing is left for a drain the app starts, and the stream told no second drain.
            #expect(try await copy.queue.drain().verdicts.isEmpty)
            try await Task.sleep(for: .milliseconds(500))
            #expect(heard.all.filter { if case .queueDrained = $0.origin { true } else { false } }.count == 1)
            heard.stop()
            await copy.close()
        } catch {
            try? await own.end()
            throw error
        }
        try await own.end()
    }

    @Test func aCatchUpThatReachesTheServerFirstStillLeavesTheFollowToDrainWhatWaitedOnce() async throws {
        let own = try await OwnServer.boot()
        do {
            let copy = try await Self.hydrated(own)
            let made = try await copy.items.create(Self.note("before the server went"))
            #expect(try await copy.queue.drain().verdicts.map(\.verdict) == [.accepted])
            let heard = Heard(copy.changes())
            try await Task.sleep(for: .milliseconds(500))

            try await own.stop()
            try await eventually("the follow said the server went", within: 30) {
                heard.all.contains { if case .serverUnreachable = $0.origin { true } else { false } }
            }
            let id = try #require(made.itemId)
            let held = try #require(try await copy.items.get(id))
            _ = try await copy.items.update(id, Edit(properties: ["title": "while away"], baseVersion: held.version))

            // The follow asks again at a falling rate, so that after this wait its next
            // ask is far off: the app reaches the server first, and is told it is back.
            try await Task.sleep(for: .seconds(16))
            try await own.start()
            try await eventually("a call reached the server", within: 60) {
                do {
                    _ = try await copy.catchUp()
                    return true
                } catch {
                    return false
                }
            }
            try await eventually("the app was told the server is back", within: 30) {
                heard.all.contains { if case .serverReachable = $0.origin { true } else { false } }
            }
            // The app starts no drain: the follow it restarted still sends the write, and says so.
            try await eventually("the follow said it drained what waited", within: 60) {
                heard.all.contains { if case .queueDrained = $0.origin { true } else { false } }
            }
            let drained = heard.all.compactMap { change -> DrainReport? in
                if case .queueDrained(let report) = change.origin { report } else { nil }
            }
            #expect(drained.count == 1)
            #expect(drained.first?.verdicts.map(\.verdict) == [.accepted])
            #expect(try await Self.read(own, id).item?["properties"]?.object?["title"] == "while away")
            #expect(try await copy.queue.drain().verdicts.isEmpty)
            try await Task.sleep(for: .milliseconds(500))
            #expect(heard.all.filter { if case .queueDrained = $0.origin { true } else { false } }.count == 1)

            // The recovery did not hide the next outage from the app.
            try await own.stop()
            try await eventually("the follow said the server went again", within: 60) {
                heard.all.filter { if case .serverUnreachable = $0.origin { true } else { false } }.count == 2
            }
            heard.stop()
            await copy.close()
            try await own.start()
        } catch {
            try? await own.end()
            throw error
        }
        try await own.end()
    }

    /// A request past the copy, as the server's owner.
    static func send(_ own: OwnServer, _ method: String, _ path: String, body: [String: Any]? = nil) async throws
        -> JSONObject
    {
        var request = URLRequest(url: own.url.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(own.key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = try #require((response as? HTTPURLResponse)?.statusCode)
        try #require((200..<300).contains(status), "\(method) \(path) answered \(status)")
        return data.isEmpty ? [:] : try JSONObject(json: String(decoding: data, as: UTF8.self))
    }

    static func told(_ heard: Heard, where matches: (Change.Origin) -> Bool) -> Int {
        heard.all.filter { matches($0.origin) }.count
    }

    static func unreachable(_ origin: Change.Origin) -> Bool {
        if case .serverUnreachable = origin { true } else { false }
    }
    static func reachable(_ origin: Change.Origin) -> Bool { if case .serverReachable = origin { true } else { false } }
    static func drained(_ origin: Change.Origin) -> Bool { if case .queueDrained = origin { true } else { false } }

    /// A write a drain the app started left undelivered is drained once by the follow a
    /// recovery starts, though the server was never lost.
    ///
    /// With no outage the core starts no follow of its own after that drain, so the
    /// follow the `catchUp()` restarts is the only one that can send the write.
    @Test func aWriteALaterDrainLeftUndeliveredIsDrainedOnceByTheFollowARecoveryStarts() async throws {
        let own = try await OwnServer.boot()
        do {
            let copy = try await Self.hydrated(own)
            let heard = Heard(copy.changes())
            // Long enough for the follow to hold its stream.
            try await Task.sleep(for: .milliseconds(500))

            let note = try #require(try await copy.items.create(Self.note("answered by the app's drain")).itemId)
            let upload = try await copy.blobs.put(file: try Live.file("kept for the next stream \(UUID())"))

            // The core cannot read the cached bytes, so it sends the note and
            // leaves the upload.
            let partial = try await copy.blobs.withFile(try #require(upload.blob)) { cached in
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: cached.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cached.path) }
                return try await copy.queue.drain()
            }
            #expect(partial.answered >= 1, "the app's drain answered nothing: \(partial)")
            #expect(partial.undelivered == 1, "the app's drain left \(partial.undelivered) undelivered")
            #expect(try await Self.read(own, note).status == 200)

            // The witness: nothing else sends the upload. The server was never lost, so the
            // stream was told nothing of it, and nothing has drained since.
            try await Task.sleep(for: .seconds(1))
            #expect(Self.told(heard, where: Self.drained) == 0, "a drain ran before the recovery")
            #expect(Self.told(heard, where: Self.unreachable) == 0)
            #expect(try await copy.queue.all().first { $0.id == upload.id }?.verdict == nil)

            _ = try await copy.catchUp()
            try await eventually("the follow the recovery started drained the write left", within: 30) {
                Self.told(heard, where: Self.drained) == 1
            }
            let report = try #require(
                heard.all.compactMap { change -> DrainReport? in
                    if case .queueDrained(let report) = change.origin { report } else { nil }
                }.first)
            #expect(report.verdicts.map(\.verdict) == [.accepted])
            #expect(report.verdicts.first?.id == upload.id)
            #expect(try await copy.queue.drain().verdicts.isEmpty, "something was still queued")
            try await Task.sleep(for: .milliseconds(500))
            #expect(Self.told(heard, where: Self.drained) == 1, "the queue was drained a second time")
            #expect(heard.stops.isEmpty)
            heard.stop()
            await copy.close()
        } catch {
            try? await own.end()
            throw error
        }
        try await own.end()
    }

    /// The server answered the follow, so it is reachable, even when the answer
    /// ends the follow.
    ///
    /// A key that expires while the server is away makes the refusal certain, whenever the
    /// follow next asks.
    @Test func aFollowThatEndsOnTheServersRefusalAfterAnOutageStillTellsTheServerIsReachable() async throws {
        let own = try await OwnServer.boot()
        do {
            let expires = Date.now.addingTimeInterval(20)
            let minted = try await Self.send(
                own, "POST", "keys",
                body: [
                    "label": "Swift restart test", "source": "swift-restart-\(UUID().uuidString.prefix(8))",
                    "default_tier": "library", "type_permissions": ["core.note": "write"],
                    "expires_at": ISO8601DateFormatter().string(from: expires),
                ])
            let copy = try await WorkingCopy.open(
                store: Live.store(), server: Server(url: own.url, key: try #require(minted["key"]?.string)))
            _ = try await copy.hydrate(types: ["core.note"], tier: .library)
            let heard = Heard(copy.changes())
            try await Task.sleep(for: .milliseconds(500))

            try await own.stop()
            try await eventually("the follow said the server went", within: 15) {
                Self.told(heard, where: Self.unreachable) == 1
            }
            // The key expires while the server is away.
            try await Task.sleep(for: .seconds(max(0, expires.timeIntervalSinceNow) + 1.5))
            try await own.start()

            try await eventually("the follow ended on the refusal", within: 60) { !heard.stops.isEmpty }
            #expect(Self.told(heard, where: Self.reachable) == 1, "the server answered and was not told reachable")
            let origins = heard.all.map(\.origin)
            let back = try #require(origins.firstIndex(where: Self.reachable))
            let refused = try #require(origins.firstIndex { if case .stopped = $0 { true } else { false } })
            #expect(back < refused, "the refusal was told before the server was: \(origins)")

            // A stream added now is told the refusal and not an outage the
            // server has since ended.
            let late = Heard(copy.changes())
            try await eventually("the late stream was told", within: 10) { !late.all.isEmpty }
            try await Task.sleep(for: .milliseconds(300))
            #expect(Self.told(late, where: Self.unreachable) == 0, "a late stream was told the old outage")
            #expect(late.stops.count == 1)
            heard.stop()
            late.stop()
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
                whole, Edit(properties: ["body": "only this"], replaceProperties: true, baseVersion: wholeRead.version))
            #expect(try await copy.items.get(whole)?.properties == ["body": "only this"])
            let movedRead = try #require(try await copy.items.get(moved))
            _ = try await copy.items.update(
                moved, Edit(properties: ["status": "open"], baseVersion: movedRead.version, type: "core.task"))
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
            // (`device/reach-changed`), so the drain may end there with every
            // write answered.
            do {
                _ = try await copy.queue.drain()
            } catch MarfaError.copyExpired(reason: "reach_changed", _) {
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
