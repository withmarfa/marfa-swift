import Foundation
import MarfaTypes
import Synchronization
import Testing

@testable import Marfa

/// The id the server answers a create with, which the test sets once its write is queued.
private final class CreateAnswer: Sendable {
    let ids = Mutex<[String]>([])
    func set(_ id: String?) { ids.withLock { $0 = [id ?? "none"] } }
}

private func item(_ id: String) -> String {
    #"{"id":"\#(id)","type":"core.note","properties":{"title":"short"},"tier":"feed","version":1,"schema_version":1,"source":"app","occurred_at":"2026-11-17T12:00:00.000Z","state":"active","created_at":"2026-11-17T12:00:00.000Z","updated_at":"2026-11-17T12:00:00.000Z"}"#
}

/// A server whose root names a small `max_request_bytes`, and which answers every create it is sent.
private func serverTaking(_ limit: Int, creating ids: CreateAnswer) async throws -> LocalServer {
    try await LocalServer.start(contract: marfaContractVersion) { method, path in
        switch (method, path) {
        case (_, "/"):
            return (
                200, "application/json",
                #"{"instance_id":"test-instance","contract":\#(marfaContractVersion),"max_request_bytes":\#(limit)}"#
            )
        case ("POST", "/items"):
            return (201, "application/json", #"{"item":\#(item(ids.ids.withLock { $0.first } ?? "unknown"))}"#)
        case ("GET", _) where path.hasPrefix("/items/") && ids.ids.withLock({ path == "/items/\($0.first ?? "")" }):
            return (
                200, "application/json",
                #"{"listed":true,"item":\#(item(String(path.dropFirst("/items/".count)))),"metadata":{"tags":[]}}"#
            )
        case (_, _) where path.hasPrefix("/items/"):
            return (404, "application/json", #"{"error":{"code":"item_not_found","message":"none"}}"#)
        default: return Waiting.hydrating(method, path)
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct RequestLimitTests {
    @Test func aSaveOverTheServersLimitIsHeldOnTheDeviceAndOtherWritesGoOn() async throws {
        let sendable = CreateAnswer()
        let server = try await serverTaking(1_500, creating: sendable)
        defer { server.stop() }
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: try Server(url: server.url, key: "k"))
        _ = try await copy.hydrate(types: ["core.note"], tier: .feed)

        let large = try await copy.items.create(
            Draft(type: "core.note", properties: ["title": .string(String(repeating: "é", count: 1_000))], tier: .feed))
        let small = try await copy.items.create(Draft(type: "core.note", properties: ["title": "short"], tier: .feed))
        sendable.set(small.itemId)

        let report = try await copy.queue.drain()
        #expect(report.unsent == 1, "\(report)")
        let largeVerdict = try #require(report.verdicts.first { $0.id == large.id })
        let smallVerdict = try #require(report.verdicts.first { $0.id == small.id })
        #expect(smallVerdict.verdict == .accepted, "\(report)")

        guard case .refused(let refusal)? = largeVerdict.verdict else {
            Issue.record("expected a refusal, got \(String(describing: largeVerdict.verdict))")
            await copy.close()
            return
        }
        let limit = try #require(refusal.requestLimit)
        #expect(limit.limit == 1_500)
        // 1,000 two-byte characters are under the limit as characters and over it as bytes.
        #expect(limit.size >= 2_000, "the size counts bytes, not characters: \(limit.size)")
        #expect(refusal.reason.hasPrefix("This write is "), "\(refusal.reason)")
        // The code a direct write of that size is refused with.
        #expect(refusal.code == "over_request_limit")

        // Only the small save reached the server.
        let posts = server.log.all.filter { $0.hasPrefix("POST /items ") }
        #expect(posts.count == 1, "\(posts)")

        // It stays on the device with its reason, for the person to make smaller or discard.
        let queued = try await copy.queue.all()
        let held = try #require(queued.first { $0.id == large.id })
        guard case .refused(let kept)? = held.verdict else {
            Issue.record("the over-limit write left the queue: \(String(describing: held.verdict))")
            await copy.close()
            return
        }
        #expect(kept.requestLimit == limit)
        #expect(!held.body.isEmpty, "a refused write keeps what it carried")
        await copy.close()
    }

    @Test func aSaveAtTheLimitIsSent() async throws {
        let ids = CreateAnswer()
        let server = try await serverTaking(1_500, creating: ids)
        defer { server.stop() }
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: try Server(url: server.url, key: "k"))
        _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
        let small = try await copy.items.create(Draft(type: "core.note", properties: ["title": "short"], tier: .feed))
        ids.set(small.itemId)
        let report = try await copy.queue.drain()
        #expect(report.unsent == 0)
        #expect(report.verdicts.first?.verdict == .accepted, "\(report)")
        await copy.close()
    }
}

/// A store removal is confirmed against the writes the person saw, so an answer that arrives after the list was read
/// refuses it.
@Suite(.timeLimit(.minutes(1)))
struct RemovalAfterAnswers {
    private static func isUnsentDiffers(_ error: any Error, holding count: UInt64) -> Bool {
        guard case .unsentDiffers(_, let unsent, _)? = error as? MarfaError else { return false }
        return unsent == count
    }

    /// A store holding one unsent create of `title`, closed, and the list the person was shown of it.
    private static func storeShown(_ title: String, on server: LocalServer) async throws -> (
        store: URL, id: String, shown: UnsentWrites
    ) {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store, server: try Server(url: server.url, key: "k"))
        _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
        let made = try await copy.items.create(
            Draft(type: "core.note", properties: ["title": .string(title)], tier: .feed))
        await copy.close()
        return (store, try #require(made.itemId), try await WorkingCopy.unsentWrites(in: store))
    }

    @Test func aWriteTheServerTookAfterTheListWasReadRefusesTheRemoval() async throws {
        let ids = CreateAnswer()
        let server = try await serverTaking(1_500, creating: ids)
        defer { server.stop() }
        let (store, id, shown) = try await Self.storeShown("short", on: server)
        ids.set(id)
        let copy = try await WorkingCopy.open(store: store, server: try Server(url: server.url, key: "k"))
        _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
        let report = try await copy.queue.drain()
        #expect(report.verdicts.first?.verdict == .accepted, "\(report)")
        await copy.close()

        await #expect {
            try await WorkingCopy.remove(store: store, confirming: shown)
        } throws: { Self.isUnsentDiffers($0, holding: 0) }
        #expect(FileManager.default.fileExists(atPath: store.path))

        // The witness: what the store holds now, read again, is removed.
        try await WorkingCopy.remove(store: store, confirming: try await WorkingCopy.unsentWrites(in: store))
        #expect(!FileManager.default.fileExists(atPath: store.path))
    }

    @Test func aWriteWhoseVerdictChangedUnderTheSameIdRefusesTheRemoval() async throws {
        let server = try await serverTaking(1_500, creating: CreateAnswer())
        defer { server.stop() }
        let (store, id, shown) = try await Self.storeShown(String(repeating: "é", count: 1_000), on: server)
        #expect(shown.writes.map(\.itemId) == [id])
        #expect(shown.writes.first?.verdict == nil)
        let copy = try await WorkingCopy.open(store: store, server: try Server(url: server.url, key: "k"))
        _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
        let report = try await copy.queue.drain()
        #expect(report.unsent == 1, "the over-limit write stays unsent: \(report)")
        await copy.close()

        let now = try await WorkingCopy.unsentWrites(in: store)
        #expect(now.writes.map(\.id) == shown.writes.map(\.id), "the same write")
        #expect(now.writes.first?.verdict != nil)
        #expect(now.confirmation != shown.confirmation)
        await #expect {
            try await WorkingCopy.remove(store: store, confirming: shown)
        } throws: { Self.isUnsentDiffers($0, holding: 1) }
        #expect(FileManager.default.fileExists(atPath: store.path))

        try await WorkingCopy.remove(store: store, confirming: now)
        #expect(!FileManager.default.fileExists(atPath: store.path))
    }
}
