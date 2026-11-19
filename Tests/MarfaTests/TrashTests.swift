import Foundation
import Synchronization
import Testing

@testable import Marfa
@testable import MarfaAPI

/// Previewing and trashing several items, against a server that answers what the contract says it does.
@Suite(.timeLimit(.minutes(1)))
struct SeveralItemTrash {
    private static let digest = String(repeating: "d", count: 64)
    private static let taken = Live.uuidV7()
    private static let other = Live.uuidV7()

    private static func root(_ release: String) -> String {
        #"{"name":"t","version":"\#(release)","release":null,"instance_id":"test-instance","contract":\#(marfaContractVersion),"features":[]}"#
    }

    /// A preview naming `a`, which takes two items, `cut` when its takes were cut at the limit.
    private static func preview(_ ids: [String], cut: Bool = false) -> String {
        let items = ids.map { id in
            id == "a"
                ? #"{"id":"a","type":"core.note","version":3,"takes":[{"id":"\#(taken)","type":"core.note","version":1},{"id":"\#(other)","type":"core.note","version":2}],"count":3,"truncated":\#(cut)}"#
                : #"{"id":"\#(id)","type":"core.note","version":1,"takes":[],"count":1,"truncated":false}"#
        }
        let count = ids.contains("a") ? ids.count + 2 : ids.count
        return #"{"items":[\#(items.joined(separator: ","))],"count":\#(count),"digest":"\#(digest)"}"#
    }

    private static func server(
        release: String = "0.0.80", cut: Bool = false, trash: @escaping @Sendable () -> LocalServer.Answer
    ) async throws -> LocalServer {
        try await LocalServer.start(contract: marfaContractVersion) { method, path in
            switch (method, path) {
            case ("GET", "/"): return (200, "application/json", root(release))
            case ("POST", "/items/trash-preview"): return (200, "application/json", preview(["a", "z"], cut: cut))
            case ("POST", "/items/trash"): return trash()
            default: return (404, "application/json", #"{"error":{"code":"not_found","message":"no"}}"#)
            }
        }
    }

    private static func open(_ server: LocalServer) async throws -> WorkingCopy {
        try await WorkingCopy.open(store: temporaryStore(), server: try Server(url: server.url, key: "key"))
    }

    @Test func aPreviewNamesEachItemOnceWithWhatItsTrashTakes() async throws {
        let server = try await Self.server { (200, "application/json", "{}") }
        defer { server.stop() }
        let copy = try await Self.open(server)
        let preview = try await copy.items.previewTrash(ids: ["a", "z", "a"])
        #expect(preview.count == 4)
        #expect(preview.items.map(\.id) == ["a", "z"])
        #expect(preview.items[0].takes.map(\.id) == [Self.taken, Self.other])
        #expect(preview.items[0].count == 3 && preview.items[0].version == 3 && !preview.items[0].truncated)
        #expect(preview.items[1].takes.isEmpty)
        let sent = try #require(server.log.all.last { $0.hasPrefix("POST /items/trash-preview") })
        #expect(sent.contains(#"{"ids":["a","z"]}"#), "an ID named twice goes once: \(sent)")
        await copy.close()
    }

    @Test(arguments: [0, 21])
    func aPreviewOfNoItemsOrMoreThanTwentySendsNothing(count: Int) async throws {
        let server = try await Self.server { (200, "application/json", "{}") }
        defer { server.stop() }
        let copy = try await Self.open(server)
        await #expect {
            _ = try await copy.items.previewTrash(ids: (0..<count).map { "item-\($0)" })
        } throws: { error in
            if case .validation(let code, _, _, _)? = error as? MarfaError { code == "validation_error" } else { false }
        }
        #expect(!server.log.all.contains { $0.hasPrefix("POST") })
        await copy.close()
    }

    @Test func aTrashSendsTheIdsAndTheDigestAndAnUnsettledCopyStillGetsItsReport() async throws {
        let server = try await Self.server { (200, "application/json", "{}") }
        defer { server.stop() }
        let copy = try await Self.open(server)
        let preview = try await copy.items.previewTrash(ids: ["a", "z"])
        let told = Mutex<[Change]>([])
        let changes = copy.changes()
        let listening = Task {
            for await change in changes { told.withLock { $0.append(change) } }
        }
        let report = try await copy.items.trash(preview)
        let sent = try #require(server.log.all.last { $0.hasPrefix("POST /items/trash ") })
        #expect(sent.contains(Self.digest) && sent.contains(#""ids":["a","z"]"#), "\(sent)")
        // This server keeps no event log, so the copy cannot catch up: the trash still happened.
        #expect(!report.settled)
        #expect(report.behind?.isEmpty == false)
        try await eventually("the app is told rows changed") {
            told.withLock { $0.contains { if case .refreshed(.trashed) = $0.origin { true } else { false } } }
        }
        listening.cancel()
        await copy.close()
    }

    @Test func aPreviewThatNoLongerMatchesIsRefusedAsItsOwnCaseAndTheCopyIsUntouched() async throws {
        let server = try await Self.server {
            (
                409, "application/json",
                #"{"error":{"code":"trash_plan_changed","message":"changed","details":{"digest":"\#(String(repeating: "e", count: 64))"}}}"#
            )
        }
        defer { server.stop() }
        let copy = try await Self.open(server)
        let preview = try await copy.items.previewTrash(ids: ["a", "z"])
        await #expect {
            _ = try await copy.items.trash(preview)
        } throws: { error in
            guard case .trashPlanChanged(_, let answer)? = error as? MarfaError else { return false }
            return answer?.status == 409 && answer?.code == "trash_plan_changed"
        }
        #expect(try await copy.queue.all().isEmpty)
        await copy.close()
    }

    @Test func aWaitingWriteToAnItemTheTrashTakesRefusesItBeforeAnythingIsSent() async throws {
        let server = try await Self.server { (200, "application/json", "{}") }
        defer { server.stop() }
        let copy = try await Self.open(server)
        let preview = try await copy.items.previewTrash(ids: ["a", "z"])
        // A create that names an item the trash takes with `a` has no answer yet.
        let queued = try await copy.items.create(
            Draft(type: "core.note", properties: ["title": "kept"], id: Self.taken))
        await #expect {
            _ = try await copy.items.trash(preview)
        } throws: { error in
            guard case .invalid(let message)? = error as? MarfaError else { return false }
            return message.contains(queued.id) && message.contains("clear each")
        }
        #expect(!server.log.all.contains { $0.hasPrefix("POST /items/trash ") }, "nothing was sent")
        #expect(try await copy.queue.all().map(\.id) == [queued.id], "the person's write stays queued")
        await copy.close()
    }

    @Test func aWriteIsRefusedWhileATrashWhoseTakesWereCutIsOutAndAllowedAfterwards() async throws {
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let server = try await Self.server(cut: true) {
            entered.signal()
            proceed.wait()
            return (200, "application/json", "{}")
        }
        defer { server.stop() }
        let copy = try await Self.open(server)
        let preview = try await copy.items.previewTrash(ids: ["a", "z"])
        #expect(preview.items[0].truncated)
        let trashing = Task { try await copy.items.trash(preview) }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                entered.wait()
                continuation.resume()
            }
        }
        // What a cut `takes` leaves out cannot be known, so a create naming an ID is refused, whichever it is.
        let named = Live.uuidV7()
        await #expect {
            _ = try await copy.items.create(Draft(type: "core.note", properties: ["title": "x"], id: named))
        } throws: { error in
            if case .itemBeingRemoved(let id, _)? = error as? MarfaError { id == named } else { false }
        }
        #expect(try await copy.queue.all().isEmpty, "nothing was queued while the trash was out")
        proceed.signal()
        _ = try await trashing.value
        _ = try await copy.items.create(Draft(type: "core.note", properties: ["title": "after"], id: Live.uuidV7()))
        await copy.close()
    }

    @Test func aServerOlderThanTheCopyWorksWithIsRefusedOnConnectBeforeAnythingElseIsAsked() async throws {
        let server = try await Self.server(release: "0.0.77") { (200, "application/json", "{}") }
        defer { server.stop() }
        let copy = try await Self.open(server)
        await #expect {
            _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
        } throws: { error in
            guard case .serverTooOld(let served, let oldest, let message)? = error as? MarfaError else { return false }
            return served == "0.0.77" && oldest == "0.0.78" && message.contains("0.0.77")
        }
        #expect(server.log.all.allSatisfy { $0.hasPrefix("GET / ") }, "only the root was read: \(server.log.all)")
        await copy.close()
    }
}
