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
            let id = ids.ids.withLock { $0.first } ?? "unknown"
            return (
                201, "application/json",
                #"{"id":"\#(id)","type":"core.note","properties":{},"version":1,"state":"active"}"#
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
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: Server(url: server.url, key: "k"))
        _ = try await copy.hydrate(types: ["core.note"], tier: .feed)

        let large = try await copy.items.create(
            Draft(type: "core.note", properties: ["title": .string(String(repeating: "é", count: 2_000))], tier: .feed))
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
        #expect(limit.size > 1_500)
        #expect(refusal.reason.hasPrefix("This write is "), "\(refusal.reason)")
        #expect(refusal.code == nil)

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
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: Server(url: server.url, key: "k"))
        _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
        let small = try await copy.items.create(Draft(type: "core.note", properties: ["title": "short"], tier: .feed))
        ids.set(small.itemId)
        let report = try await copy.queue.drain()
        #expect(report.unsent == 0)
        let stored = try await copy.queue.all()
        #expect(report.verdicts.first?.verdict != nil, "\(stored)")
        #expect(report.verdicts.first?.verdict == .accepted, "\(report)")
        await copy.close()
    }
}
