import Foundation
import MarfaTypes
import Synchronization
import Testing

@testable import Marfa

/// The real core over HTTP: the server controls page failures and the event log's retention boundary.
@Suite(.timeLimit(.minutes(1)))
struct HydrationLifecycle {
    @Test(arguments: [false, true])
    func readsAndWritesWorkWhileAFillIsWaitingForItsNextPage(refilling: Bool) async throws {
        let script = HydrationScript()
        let server = try await script.start()
        defer { server.stop() }
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: Server(url: server.url, key: "test"))
        if refilling {
            script.set("/items", [.page(["held", "gone"])])
            _ = try await copy.hydrate(types: ["*"], tier: .library)
            script.set("/events", [.agedOut])
            await #expect(throws: MarfaError.self) { _ = try await copy.catchUp() }
            script.set("/events", [.stream(cursor: "60")])
        }
        let gate = HydrationScript.Gate()
        defer { gate.release() }
        script.set("/items", [.page(["held"], next: "next"), .page(["arrived"]).waiting(on: gate)])
        let filling = Task { try await copy.hydrate(types: ["*"], tier: .library) }
        defer { filling.cancel() }
        try await eventually("the second page was requested", within: 10) { gate.entered.withLock { $0 } }
        try #require(gate.entered.withLock { $0 })
        #expect(try await copy.status().itemsListed == 1)
        #expect(try await copy.items.list().completeness == (refilling ? .stale : .partial))
        let queued = try await Self.queueEdits(copy)
        gate.release()
        let report = try await bounded("the fill completes") { try await filling.value }
        #expect(report.inPlace == refilling)
        #expect(try await copy.items.list().completeness == .complete)
        try await Self.expectEdits(copy, queued: queued)
        await copy.close()
    }

    @Test(arguments: [false, true])
    func anInterruptedFillKeepsWritesAndReportsWhetherItResumed(changingSlice: Bool) async throws {
        let script = HydrationScript()
        let server = try await script.start()
        defer { server.stop() }
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: Server(url: server.url, key: "test"))
        script.set("/items", [.page(["held"], next: "next"), .unavailable])
        await #expect(throws: MarfaError.self) { _ = try await copy.hydrate(types: ["*"], tier: .library) }

        let status = try await copy.status()
        #expect(status.hydration == .inProgress)
        #expect(status.itemsListed == 1 && status.itemsExpected == 2)
        let partial = try await copy.items.list()
        #expect(partial.completeness == .partial && partial.map(\.id) == ["held"])
        #expect(try await copy.search("held").completeness == .partial)
        let queued = try await Self.queueEdits(copy)
        #expect(try await copy.status().itemsListed == 1, "a queued create is not fill progress")
        let requestsBefore = server.log.all.count
        #expect(try await copy.queue.all().map(\.id) == queued)
        #expect(server.log.all.count == requestsBefore, "reading the queue sent a request")

        script.set("/items", changingSlice ? [.page(["held", "arrived"])] : [.page(["arrived"])])
        let report = try await copy.hydrate(types: ["*"], tier: changingSlice ? .all : .library)
        #expect(report.resumed == !changingSlice)
        #expect(report.restarted == (changingSlice ? "slice_changed" : nil))
        #expect(report.pages == 1 && report.pagesTotal == (changingSlice ? 1 : 2))
        #expect(!report.inPlace)
        let pageRequest = try #require(server.log.all.last { $0.hasPrefix("GET /items?") })
        #expect(pageRequest.contains("cursor=next") == !changingSlice)
        try await Self.expectEdits(copy, queued: queued)
        #expect(try await copy.items.list().completeness == .complete)
        #expect(try await copy.items.get("arrived") != nil)
        #expect(!server.log.all.contains { $0.hasPrefix("POST /items ") || $0.hasPrefix("PATCH ") })
        script.set("/items/held", [.unavailable])
        script.set("/items", [.unavailable])
        _ = try await copy.queue.drain()
        #expect(
            server.log.all.contains { $0.hasPrefix("PATCH /items/held?") }, "the completed copy did not send its edit")
        await copy.close()
    }

    @Test func anAgedOutCopyRefillsInPlaceAndKeepsWritesAcrossAnInterruptedRefill() async throws {
        let script = HydrationScript()
        let server = try await script.start()
        defer { server.stop() }
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: Server(url: server.url, key: "test"))
        script.set("/items", [.page(["held", "gone"])])
        _ = try await copy.hydrate(types: ["*"], tier: .library)
        #expect(try await copy.items.list().completeness == .complete)
        #expect(try await copy.items.get("gone") != nil)

        script.set("/events", [.agedOut])
        let beforeCatchUp = server.log.all.count
        await #expect { _ = try await copy.catchUp() } throws: { error in
            if case .copyExpired = error as? MarfaError { true } else { false }
        }
        #expect(server.log.all.count > beforeCatchUp, "the complete copy did not request catch-up")
        #expect(try await copy.status().hydration == .stale)
        #expect(try await copy.items.list().completeness == .stale)
        #expect(try await copy.search("gone").completeness == .stale)
        let queued = try await Self.queueEdits(copy)
        let requestsBefore = server.log.all.count
        await #expect { _ = try await copy.queue.drain() } throws: { error in
            if case .copyExpired(let reason, _) = error as? MarfaError { reason == "catchup_too_old" } else { false }
        }
        await #expect { _ = try await copy.catchUp() } throws: { error in
            if case .copyExpired(let reason, _) = error as? MarfaError { reason == "catchup_too_old" } else { false }
        }
        #expect(server.log.all.count == requestsBefore, "a stale copy sent a catch-up or a drain")

        script.set("/events", [.stream(cursor: "60")])
        script.set("/items", [.page(["held"], next: "next"), .unavailable])
        await #expect(throws: MarfaError.self) { _ = try await copy.hydrate(types: ["*"], tier: .library) }
        #expect(try await copy.status().hydration == .stale)
        #expect(try await copy.items.list().completeness == .stale)
        #expect(try await copy.items.get("gone") != nil, "an unfinished refill removed an old row")
        try await Self.expectEdits(copy, queued: queued)

        script.set("/items", [.page(["arrived"])])
        let report = try await copy.hydrate(types: ["*"], tier: .library)
        #expect(report.inPlace && report.resumed && report.restarted == nil)
        #expect(report.pages == 1 && report.pagesTotal == 2)
        #expect(try await copy.status().hydration == .complete)
        #expect(try await copy.items.list().completeness == .complete)
        #expect(try await copy.items.get("gone") == nil)
        #expect(try await copy.items.get("arrived") != nil)
        try await Self.expectEdits(copy, queued: queued)
        #expect(!server.log.all.contains { $0.hasPrefix("POST /items ") || $0.hasPrefix("PATCH ") })
        await copy.close()
    }

    @Test func aHeldStreamRefillsAStaleCopyInPlaceWhenTheServerSaysItsCursorAgedOut() async throws {
        let script = HydrationScript()
        let server = try await script.start()
        defer { server.stop() }
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: Server(url: server.url, key: "test"))
        script.set("/items", [.page(["held", "gone"])])
        _ = try await copy.hydrate(types: ["*"], tier: .library)
        script.set("/events", [.agedOut, .stream(cursor: "60")])
        script.set("/items", [.page(["held"])])
        let heard = Heard(copy.changes())
        try await eventually("the refill was told", within: 10) {
            heard.all.contains { if case .refreshed(.hydrated) = $0.origin { true } else { false } }
        }
        #expect(heard.stops.isEmpty)
        #expect(try await copy.status().hydration == .complete)
        #expect(try await copy.items.get("gone") == nil)
        await copy.close()
    }

    private static func staleCopy(_ script: HydrationScript, _ server: LocalServer) async throws -> WorkingCopy {
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: Server(url: server.url, key: "test"))
        script.set("/items", [.page(["held", "gone"])])
        _ = try await copy.hydrate(types: ["*"], tier: .library)
        script.set("/events", [.agedOut])
        await #expect(throws: MarfaError.self) { _ = try await copy.catchUp() }
        try #require(try await copy.status().hydration == .stale)
        return copy
    }

    private static func refused(_ reason: String) -> (any Error) -> Bool {
        { error in
            if case .copyExpired(let given, _)? = error as? MarfaError { given == reason } else { false }
        }
    }

    @Test(arguments: [(["core.note"], SliceTier.library), (["*"], SliceTier.all)])
    func aFillOnlyInPlaceOverAnotherSliceIsRefusedBeforeItChangesAnythingAndTheCopyStaysStale(
        types: [String], tier: SliceTier
    ) async throws {
        let script = HydrationScript()
        let server = try await script.start()
        defer { server.stop() }
        let copy = try await Self.staleCopy(script, server)
        let queued = try await Self.queueEdits(copy)
        script.set("/events", [.stream(cursor: "60")])
        script.set("/items", [.page(["arrived"])])
        let before = server.log.all.count

        await #expect(
            performing: { _ = try await copy.hydrate(types: types, tier: tier, inPlaceOnly: true) },
            throws: Self.refused("slice_changed"))

        #expect(try await copy.status().hydration == .stale, "a kept copy reads stale")
        #expect(try await copy.items.get("gone") != nil)
        #expect(try await copy.items.get("arrived") == nil)
        try await Self.expectEdits(copy, queued: queued)
        #expect(!server.log.all.dropFirst(before).contains { $0.hasPrefix("GET /items?") }, "it read a page first")

        // The same slice fills in place, and keeps the queue.
        let report = try await copy.hydrate(types: ["*"], tier: .library, inPlaceOnly: true)
        #expect(report.inPlace)
        #expect(try await copy.status().hydration == .complete)
        #expect(try await copy.items.get("gone") == nil)
        #expect(try await copy.items.get("arrived") != nil)
        try await Self.expectEdits(copy, queued: queued)
        await copy.close()
    }

    @Test func aCompleteCopyAskedToFillOnlyInPlaceIsNotStaleAndKeepsEverything() async throws {
        let script = HydrationScript()
        let server = try await script.start()
        defer { server.stop() }
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: Server(url: server.url, key: "test"))
        script.set("/items", [.page(["held", "gone"])])
        _ = try await copy.hydrate(types: ["*"], tier: .library)

        await #expect(
            performing: { _ = try await copy.hydrate(types: ["*"], tier: .library, inPlaceOnly: true) },
            throws: Self.refused("not_stale"))

        #expect(try await copy.status().hydration == .complete)
        #expect(try await copy.items.get("gone") != nil)
        await copy.close()
    }

    @Test func aFillOnlyInPlaceThatTheServerRefusesEndsTheCopyWhichReadsExpiredNotStale() async throws {
        let script = HydrationScript()
        let server = try await script.start()
        defer { server.stop() }
        let copy = try await Self.staleCopy(script, server)
        script.set("/events", [.stream(cursor: "60")])
        script.set("/items", [.refused])

        await #expect(throws: MarfaError.self) {
            _ = try await copy.hydrate(types: ["*"], tier: .library, inPlaceOnly: true)
        }

        #expect(try await copy.status().hydration == .expired, "an ended copy reads expired")
        await copy.close()
    }

    @Test func aWriteHeldForAnotherInstanceIsReleasedToTheCurrentOneOrWithdrawn() async throws {
        let script = HydrationScript()
        let server = try await script.start()
        defer { server.stop() }
        let copy = try await WorkingCopy.open(store: temporaryStore(), server: Server(url: server.url, key: "test"))
        script.set("/items", [.page(["held", "gone"])])
        _ = try await copy.hydrate(types: ["*"], tier: .library)
        let queued = try await Self.queueEdits(copy)

        // The server is now another instance, so a fill that keeps the copy is refused, naming why.
        script.set("/", [.another])
        script.set("/events", [.stream(cursor: "60", instance: "another")])
        await #expect(
            performing: { _ = try await copy.hydrate(types: ["*"], tier: .library, inPlaceOnly: true) },
            throws: { error in
                if case .instanceChanged? = error as? MarfaError { true } else { false }
            })
        #expect(try await copy.queue.all().map(\.id) == queued, "the refusal changed the queue")

        // Hydrating afresh builds the copy from the other instance and holds the writes queued before it.
        script.set("/items", [.page(["held"])])
        _ = try await copy.hydrate(types: ["*"], tier: .library)
        let held = try await copy.queue.all()
        #expect(held.map(\.id) == queued)
        #expect(held.allSatisfy { if case .blocked(.instanceChanged, _)? = $0.verdict { true } else { false } })

        // One held write is withdrawn, which reads its row from the server.
        let withdrawn = try await copy.queue.withdraw(queued[1])
        #expect(withdrawn)
        // The other is released to the current instance and goes on the next drain.
        #expect(try await copy.queue.release(reason: .instanceChanged) == 1)
        script.set("/items/held", [.unavailable])
        _ = try? await copy.queue.drain()
        #expect(server.log.all.contains { $0.hasPrefix("PATCH /items/held?") }, "the released write was not sent")
        await copy.close()
    }

    private static func queueEdits(_ copy: WorkingCopy) async throws -> [String] {
        let held = try #require(try await copy.items.get("held"))
        let edit = try await copy.items.update(
            held.id, Edit(properties: ["title": "local title"], baseVersion: held.version))
        let create = try await copy.items.create(Draft(type: "core.note", properties: ["title": "local create"]))
        return [edit.id, create.id]
    }

    private static func expectEdits(_ copy: WorkingCopy, queued: [String]) async throws {
        #expect(try await copy.items.get("held")?.title == "local title")
        let writes = try await copy.queue.all()
        #expect(writes.map(\.id) == queued)
        let created = try #require(writes.last?.itemId)
        #expect(try await copy.items.get(created)?.title == "local create")
    }
}

private final class HydrationScript: Sendable {
    private let answers = Mutex<[String: [Response]]>([:])

    final class Gate: Sendable {
        let entered = Mutex(false)
        private let ready = DispatchSemaphore(value: 0)

        func release() { ready.signal() }

        func wait() {
            entered.withLock { $0 = true }
            if ready.wait(timeout: .now() + 30) == .timedOut {
                Issue.record("the test did not release the hydration page")
            }
        }
    }

    func set(_ path: String, _ responses: [Response]) {
        answers.withLock { $0[path] = responses }
    }

    func start() async throws -> LocalServer {
        try await LocalServer.start(contract: marfaContractVersion) { [self] _, path in
            let response = answers.withLock { scripts -> Response? in
                guard let first = scripts[path]?.first else { return nil }
                if scripts[path]!.count > 1 { scripts[path]!.removeFirst() }
                return first
            }
            if let response {
                response.gate?.wait()
                return response.answer
            }
            switch path {
            case "/":
                return Response.json(
                    #"{"name":"t","version":"1","release":null,"instance_id":"test-instance","contract":\#(marfaContractVersion),"features":[]}"#
                ).answer
            case "/types":
                return Response.json(
                    #"{"data":[{"id":"core.note","display_hints":{"title_field":"title"},"fields":{"title":{"type":"string"}}}],"next_cursor":null}"#
                ).answer
            case "/keys/current": return Response.json(#"{"type_permissions":{"*":"write"}}"#).answer
            case "/items/stats": return Response.json(#"{"core.note":2}"#).answer
            case "/events": return Response.stream(cursor: "10").answer
            case "/items/bulk-get": return Response.json(#"{"items":[],"metadata":[],"listed":[]}"#).answer
            case "/edge-types": return Response.json(#"{"data":[],"next_cursor":null}"#).answer
            default: return (404, "application/json", #"{"error":{"code":"not_found","message":"unscripted"}}"#)
            }
        }
    }

    struct Response: Sendable {
        var answer: LocalServer.Answer
        var gate: Gate?

        func waiting(on gate: Gate) -> Self { Self(answer: answer, gate: gate) }

        static func json(_ body: String) -> Self { Self(answer: (200, "application/json", body)) }

        static func page(_ ids: [String], next: String? = nil) -> Self {
            let rows = ids.map { id in
                #"{"item":{"id":"\#(id)","type":"core.note","properties":{"title":"\#(id)"},"state":"active","tier":"library","version":1,"schema_version":1,"source":"test","occurred_at":"2026-01-01T00:00:00Z","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"},"metadata":{"tags":[]},"listed":true}"#
            }
            let cursor = next.map { "\"\($0)\"" } ?? "null"
            return .json(#"{"data":[\#(rows.joined(separator: ","))],"next_cursor":\#(cursor)}"#)
        }

        static func stream(cursor: String, instance: String = "test-instance") -> Self {
            Self(
                answer: (
                    200, "text/event-stream",
                    marker("stream_cursor", cursor: cursor, instance: instance)
                        + marker("stream_live", cursor: cursor, instance: instance)
                ))
        }

        static let another = Self.json(
            #"{"name":"t","version":"1","release":null,"instance_id":"another","contract":\#(marfaContractVersion),"features":[]}"#
        )

        static let refused = Self(
            answer: (401, "application/json", #"{"error":{"code":"unauthorized","message":"the key was refused"}}"#))

        static let unavailable = Self(
            answer: (503, "application/json", #"{"error":{"code":"unavailable","message":"interrupted"}}"#))
        static let agedOut = Self(
            answer: (
                200, "text/event-stream",
                marker("stream_cursor", cursor: "60")
                    + "event: catchup_too_old\ndata: {\"event_type\":\"catchup_too_old\",\"min_retained_id\":\"50\",\"requested\":\"10\"}\n\n"
            ))

        private static func marker(_ kind: String, cursor: String, instance: String = "test-instance") -> String {
            "event: \(kind)\ndata: {\"event_type\":\"\(kind)\",\"cursor\":\"\(cursor)\",\"instance_id\":\"\(instance)\",\"reach\":\"\(LocalServer.reach)\"}\n\n"
        }
    }
}
