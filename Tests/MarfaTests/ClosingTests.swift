import Foundation
import MarfaCoreNames
import MarfaTypes
import Synchronization
import Testing

@testable import Marfa

private func isClosed(_ error: any Error) -> Bool {
    if case MarfaError.closed = error { true } else { false }
}

private func refused(_ what: String, _ call: () async throws -> Void) async {
    do {
        try await call()
        Issue.record("\(what) worked on a closed copy")
    } catch {
        #expect(isClosed(error), "\(what) threw \(error), not closed")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct Closing {
    @Test func closingReleasesTheStoreSoTheNextOpenerWrites() async throws {
        let store = temporaryStore()
        let first = try await WorkingCopy.open(store: store)
        #expect(first.handle == .writer)
        let held = try await WorkingCopy.open(store: store)
        #expect(held.handle == .reader, "the writer's claim was not held, so this proves nothing")
        await held.close()

        try await bounded("close") { await first.close() }

        let second = try await WorkingCopy.open(store: store)
        #expect(second.handle == .writer, "the closed copy still held the store")
        await second.close()
    }

    @Test func closingTwiceAtOnceReturnsOnlyOnceTheStoreIsReleased() async throws {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        try await bounded("both closes") {
            async let first: Void = copy.close()
            async let second: Void = copy.close()
            _ = await (first, second)
        }
        await copy.close()
        let next = try await WorkingCopy.open(store: store)
        #expect(next.handle == .writer)
        await next.close()
    }

    @Test func everyCallOnAClosedCopyThrowsClosed() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        await copy.close()

        await refused("status") { _ = try await copy.status() }
        await refused("hydrate") { _ = try await copy.hydrate(types: ["core.note"], tier: .feed) }
        await refused("catchUp") { _ = try await copy.catchUp() }
        await refused("search") { _ = try await copy.search("a") }
        await refused("items.list") { _ = try await copy.items.list() }
        await refused("items.get") { _ = try await copy.items.get("a") }
        await refused("items.thumbnail") { _ = try await copy.items.thumbnail("a") }
        await refused("items.create") {
            _ = try await copy.items.create(Draft(type: "core.note", properties: [:], tier: .feed))
        }
        await refused("items.delete") { _ = try await copy.items.delete("a") }
        await refused("edges.from") { _ = try await copy.edges.from("a") }
        await refused("edges.to") { _ = try await copy.edges.to("a") }
        await refused("edges.ofType") { _ = try await copy.edges.ofType("attached-to") }
        await refused("edges.create") { _ = try await copy.edges.create(from: "a", to: "b", type: "attached-to") }
        await refused("tags.add") { _ = try await copy.tags.add("t", to: "a") }
        await refused("metadata.mergeTags") { _ = try await copy.metadata.mergeTags(["t"], into: "a") }
        await refused("extensions.write") { _ = try await copy.extensions.write("n", [:], on: "a") }
        await refused("extensions.delete") { _ = try await copy.extensions.delete("n", from: "a") }
        await refused("blobs.get") { _ = try await copy.blobs.get("h") }
        await refused("blobs.isHeld") { _ = try await copy.blobs.isHeld("h") }
        await refused("queue.all") { _ = try await copy.queue.all() }
        await refused("queue.drain") { _ = try await copy.queue.drain() }
        await refused("queue.forgetAnswered") { _ = try await copy.queue.forgetAnswered() }
        await refused("queue.release") { _ = try await copy.queue.release("a") }
        await refused("queue.withdraw") { _ = try await copy.queue.withdraw("a") }
        await refused("queue.discard") { _ = try await copy.queue.discard("a") }
        await refused("catalog.itemTypes") { _ = try await copy.catalog.itemTypes() }
        await refused("catalog.edgeType") { _ = try await copy.catalog.edgeType("attached-to") }
        await refused("useKey") { try await copy.useKey("k") }

        var heard = copy.changes().makeAsyncIterator()
        #expect(await heard.next() == nil, "a stream from a closed copy was left open")
    }

    @Test func aCallRacingCloseCompletesOrThrowsClosed() async throws {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        let outcomes = try await bounded("the race") {
            await withTaskGroup(of: [String].self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        var seen: [String] = []
                        for _ in 0..<60 {
                            do {
                                _ = try await copy.queue.all()
                                seen.append("completed")
                            } catch {
                                seen.append(isClosed(error) ? "closed" : "\(error)")
                            }
                        }
                        return seen
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(5))
                    await copy.close()
                    return []
                }
                return await group.reduce(into: []) { $0 += $1 }
            }
        }
        #expect(Set(outcomes).isSubset(of: ["completed", "closed"]), "\(Set(outcomes))")
        let next = try await WorkingCopy.open(store: store)
        #expect(next.handle == .writer)
        await next.close()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ChangingTheKey {
    private static let elsewhere = Server(url: URL(string: "http://127.0.0.1:9")!, key: "old-key")

    @Test func theCopyReopensTheSameStoreAndKeepsTheWriterRole() async throws {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store, server: Self.elsewhere)
        let written = try await copy.queue.all()
        try await bounded("useKey") { try await copy.useKey("new-key") }

        #expect(copy.handle == .writer)
        #expect(try await copy.queue.all() == written)
        let other = try await WorkingCopy.open(store: store)
        #expect(other.handle == .reader, "the reopened copy does not hold the writer role")
        await other.close()
        await copy.close()
        let after = try await WorkingCopy.open(store: store)
        #expect(after.handle == .writer)
        await after.close()
    }

    @Test func theServerIsAskedWithTheNewKeyAfterwards() async throws {
        let server = try await LocalServer.start(contract: marfaContractVersion, answer: Waiting.hydrating)
        defer { server.stop() }
        let copy = try await WorkingCopy.open(
            store: temporaryStore(), server: Server(url: server.url, key: "old-key"))
        _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
        #expect(server.log.all.last?.contains("old-key") == true, "the old key was never sent, so this proves nothing")
        let before = server.log.all.count

        try await copy.useKey("new-key")
        _ = try await copy.catchUp()

        let after = Array(server.log.all.dropFirst(before))
        #expect(!after.isEmpty)
        #expect(after.allSatisfy { $0.contains("new-key") && !$0.contains("old-key") }, "\(after)")
        await copy.close()
    }

    @Test func aCopyWithNoServerHasNoKeyToChange() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        do {
            try await copy.useKey("k")
            Issue.record("a copy with no server took a key")
        } catch MarfaError.noServer {
        }
        _ = try await copy.queue.all()
        await copy.close()
    }

    @Test func aHeldFollowEndsOnTheOldCoreAndStartsAgainOnTheNew() async throws {
        let old = FakeCore.writer()
        let new = FakeCore.writer()
        let keys = Mutex<[String]>([])
        let copy = WorkingCopy(
            holder: CoreHolder(
                old,
                reopen: { key in
                    keys.withLock { $0.append(key) }
                    #expect(old.follows[0].ended, "the old follow still held the store when it was reopened")
                    return new
                }),
            hasServer: true)
        let heard = Heard(copy.changes())
        #expect(old.follows.count == 1)

        try await bounded("useKey") { try await copy.useKey("new-key") }

        #expect(keys.withLock { $0 } == ["new-key"])
        try await eventually("the follow started on the new core") { new.follows.count == 1 }
        new.change(0, CoreChange(event: "item.created", itemId: "n1", edgeId: nil, cursor: "2"))
        try await eventually("the stream heard the new core") { heard.all.count == 1 }
        #expect(heard.stops.isEmpty, "the stream was told the follow stopped")
        try await bounded("close") { await copy.close() }
        #expect(new.follows[0].ended)
    }

    @Test func aFollowStoppedByTheOldKeyStartsAgainWithTheNewOne() async throws {
        let old = FakeCore.writer()
        let new = FakeCore.writer()
        let copy = WorkingCopy(holder: CoreHolder(old, reopen: { _ in new }), hasServer: true)
        let heard = Heard(copy.changes())
        old.fail(0, with: .Unauthorized(code: "unauthorized", message: "no"))
        try await eventually("the stream was told") { heard.stops.count == 1 }
        #expect(new.follows.isEmpty)

        try await bounded("useKey") { try await copy.useKey("new-key") }
        try await eventually("the follow started on the new core") { new.follows.count == 1 }
        try await bounded("close") { await copy.close() }
    }

    @Test func aWatchContinuesOnTheNewCore() async throws {
        let old = FakeCore.reader()
        let new = FakeCore.reader()
        let copy = WorkingCopy(holder: CoreHolder(old, reopen: { _ in new }), hasServer: true)
        let heard = Heard(copy.changes())
        old.save()
        try await eventually("the old core's save was told") { heard.saves.count == 1 }

        try await bounded("useKey") { try await copy.useKey("new-key") }
        new.save()
        try await eventually("the new core's save was told") { heard.saves.count == 2 }
        try await bounded("close") { await copy.close() }
    }

    @Test func aCopyThatCannotReopenIsClosedAndItsStreamsEnd() async throws {
        let copy = WorkingCopy(
            holder: CoreHolder(
                FakeCore.writer(), reopen: { _ in throw CoreMarfaError.Store(message: "cannot open") }),
            hasServer: true)
        var heard = copy.changes().makeAsyncIterator()

        do {
            try await bounded("useKey") { try await copy.useKey("k") }
            Issue.record("a store that could not be opened was reported opened")
        } catch let error as MarfaError {
            #expect(error == .store(message: "cannot open"))
        }
        #expect(await heard.next() == nil)
        await refused("status") { _ = try await copy.status() }
    }

    @Test func aCallMadeWhileTheKeyChangesIsToldToAskAgain() async throws {
        let gate = DispatchSemaphore(value: 0)
        let copy = WorkingCopy(
            holder: CoreHolder(
                FakeCore.writer(),
                reopen: { _ in
                    gate.wait()
                    return FakeCore.writer()
                }),
            hasServer: false)
        let changing = Task { try await copy.holder.replace(key: "k") }
        try await eventually("the store was being reopened") {
            do {
                _ = try await copy.status()
                return false
            } catch MarfaError.invalid {
                return true
            }
        }
        gate.signal()
        try await bounded("replace") { try await changing.value }
        _ = try await copy.status()
        await copy.close()
    }
}
