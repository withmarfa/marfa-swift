import Foundation
import MarfaTypes
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct Waiting {
    /// An empty `core.note` slice at cursor 10.
    static func hydrating(_ method: String, _ path: String) -> LocalServer.Answer {
        switch path {
        case "/events":
            (200, "text/event-stream", "event: stream_cursor\ndata: {\"type\":\"stream_cursor\",\"cursor\":\"10\"}\n\n")
        case "/types":
            (
                200, "application/json",
                #"{"data":[{"id":"core.note","fields":{"title":{"type":"string"}},"display_hints":{"title_field":"title"}}],"next_cursor":null}"#
            )
        case "/keys/current": (200, "application/json", #"{"type_permissions":{"*":"write"}}"#)
        default: LocalServer.emptyPage(method, path)
        }
    }

    /// The server goes away after the hydration, so the drain leaves the
    /// create unanswered, and the edit behind it waits.
    @Test func aWriteBehindAnUnansweredCreateWaitsWithNoVerdict() async throws {
        let server = try await LocalServer.start(contract: marfaContractVersion, answer: Self.hydrating)
        defer { server.stop() }
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: Server(url: server.url, key: "k"))
        _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
        server.stop()

        let created = try await copy.items.create(Draft(type: "core.note", properties: ["title": "a"], tier: .feed))
        let id = try #require(created.itemId)
        let edited = try await copy.items.update(id, Edit(properties: ["title": "b"], baseVersion: 0))
        let report = try await copy.queue.drain()
        #expect(report.verdicts.allSatisfy { $0.verdict == nil }, "\(report.verdicts)")

        let queue = try await copy.queue.all()
        let create = try #require(queue.first { $0.id == created.id })
        let edit = try #require(queue.first { $0.id == edited.id })
        #expect(create.verdict == nil)
        #expect(!create.waiting)
        #expect(edit.verdict == nil, "a waiting write was given a verdict")
        #expect(edit.waiting)
        #expect(edit.follows == created.id || edit.dependsOn.contains(created.id))
        await copy.close()
    }
}
