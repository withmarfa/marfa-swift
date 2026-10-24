import Foundation
import Testing

@testable import Marfa

/// A copy whose connection to its server is cut and mended, as a Mac's is when it sleeps or loses its network,
/// with a server of the test's own so its event log can be retired under it.
@Suite(
    .serialized,
    .enabled(if: OwnServer.monorepo != nil, "set MARFA_MONOREPO to a marfa checkout whose server is built"),
    .timeLimit(.minutes(5)))
struct LiveFollow {
    /// A copy that reaches `own` only through `relay`, hydrated and holding a stream with its follow running.
    static func following(_ own: OwnServer, through relay: Relay) async throws -> (WorkingCopy, Heard) {
        let copy = try await WorkingCopy.open(store: Live.store(), server: Server(url: relay.url, key: own.key))
        _ = try await copy.hydrate(types: ["core.note"], tier: .library)
        let heard = Heard(copy.changes())
        try await Task.sleep(for: .milliseconds(500))
        return (copy, heard)
    }

    /// Another device's copy, which writes to the server directly.
    static func writer(_ own: OwnServer) async throws -> WorkingCopy {
        let copy = try await WorkingCopy.open(store: Live.store(), server: own.server)
        _ = try await copy.hydrate(types: ["core.note"], tier: .library)
        return copy
    }

    static func written(_ title: String, by writer: WorkingCopy) async throws -> String {
        let made = try await writer.items.create(
            Draft(type: "core.note", properties: ["title": .string(title), "body": "b"], tier: .library))
        #expect(try await writer.queue.drain().verdicts.map(\.verdict) == [.accepted])
        return try #require(made.itemId)
    }

    static func told(_ heard: Heard, about id: String) -> Bool {
        heard.all.contains { if case .server = $0.origin { $0.itemId == id } else { false } }
    }

    static func cut(_ relay: Relay, under heard: Heard) async throws {
        relay.cut()
        try await eventually("the follow said the server went", within: 30) {
            heard.all.contains { if case .serverUnreachable = $0.origin { true } else { false } }
        }
    }

    @Test func aFollowWhoseCursorAgedOutWhileAwayFillsTheCopyAgainAndCarriesOn() async throws {
        let own = try await OwnServer.boot()
        let relay = try await Relay.start(to: own.url)
        do {
            let (copy, heard) = try await Self.following(own, through: relay)
            let writer = try await Self.writer(own)
            try await Self.cut(relay, under: heard)

            let first = try await Self.written("while away", by: writer)
            let second = try await Self.written("also while away", by: writer)
            try await own.pruneEventLog()
            relay.mend()

            try await eventually("the copy was filled again with what it missed", within: 90) {
                guard try await copy.status().hydration == .complete else { return false }
                return try await copy.items.get(second) != nil
            }
            #expect(try await copy.items.get(first) != nil)
            #expect(heard.stops.isEmpty, "the stream was told \(heard.stops)")
            #expect(heard.all.contains { $0.origin == .refreshed(.hydrated) })

            let after = try await Self.written("after the fill", by: writer)
            try await eventually("the follow told the next event", within: 60) { Self.told(heard, about: after) }
            #expect(heard.stops.isEmpty)
            heard.stop()
            await writer.close()
            await copy.close()
        } catch {
            relay.stop()
            try? await own.end()
            throw error
        }
        relay.stop()
        try await own.end()
    }

    @Test func aFollowWhoseConnectionDroppedCatchesUpOnWhatItMissed() async throws {
        let own = try await OwnServer.boot()
        let relay = try await Relay.start(to: own.url)
        do {
            let (copy, heard) = try await Self.following(own, through: relay)
            let writer = try await Self.writer(own)
            try await Self.cut(relay, under: heard)
            let missed = try await Self.written("while cut off", by: writer)
            relay.mend()

            try await eventually("the follow told what it missed", within: 60) { Self.told(heard, about: missed) }
            #expect(try await copy.items.get(missed) != nil)
            #expect(heard.stops.isEmpty, "the stream was told \(heard.stops)")
            heard.stop()
            await writer.close()
            await copy.close()
        } catch {
            relay.stop()
            try? await own.end()
            throw error
        }
        relay.stop()
        try await own.end()
    }
}
