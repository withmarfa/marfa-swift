import Foundation
import MarfaCore
import MarfaCoreNames
import Testing

@testable import Marfa

func temporaryStore() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "marfa-\(UUID()).sqlite")
}

/// Waits for `condition`, polling, and records an issue once `seconds` pass
/// without it.
func eventually(_ what: String, within seconds: Double = 5, _ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(seconds)
    while try await !condition() {
        guard Date.now < deadline else {
            Issue.record("never: \(what)")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@Suite struct Values {
    @Test func jsonRoundTripsThroughTheTextTheCoreTakes() throws {
        let properties: [String: JSONValue] = [
            "title": "A note", "count": 3, "ratio": 0.5, "done": false, "none": nil,
            "tags": ["a", "b"], "nested": ["key": "value"],
        ]
        #expect(try Properties.object(Properties.text(properties)) == properties)
    }

    @Test func anIntegerBeyondWhatADoubleHoldsComesBackExact() throws {
        let read = try Properties.object(#"{"id":9007199254740993,"ratio":0.25}"#)
        #expect(read["id"] == .integer(9_007_199_254_740_993))
        #expect(read["ratio"] == .number(0.25))
        #expect(try Properties.text(read).contains("9007199254740993"))
    }

    @Test func anItemCrossesWhole() throws {
        let item = try Item(
            CoreItem(
                id: "n1", type: "core.note", propertiesJson: #"{"title":"Heron","body":"b"}"#, state: .archived,
                tier: .feed, version: 2, schemaVersion: 3, source: "device", sourceId: "notes/heron.md",
                occurredAt: "2026-09-18T00:00:00.000Z", createdAt: "2026-09-17T00:00:00.000Z",
                updatedAt: "2026-09-19T00:00:00.000Z", tags: ["favorite"]))
        #expect(item.id == "n1")
        #expect(item.type == "core.note")
        #expect(item.title == "Heron")
        #expect(item.properties["body"] == "b")
        #expect(item.state == .archived)
        #expect(item.tier == .feed)
        #expect(item.version == 2)
        #expect(item.schemaVersion == 3)
        #expect(item.source == "device")
        #expect(item.sourceId == "notes/heron.md")
        #expect(item.occurredAt == "2026-09-18T00:00:00.000Z")
        #expect(item.createdAt == "2026-09-17T00:00:00.000Z")
        #expect(item.updatedAt == "2026-09-19T00:00:00.000Z")
        #expect(item.tags == ["favorite"])
    }

    @Test func anEdgeCrossesWhole() throws {
        let edge = try Edge(
            CoreEdge(
                id: "e1", sourceId: "a", targetId: "b", edgeType: "references", propertiesJson: #"{"w":1}"#,
                version: 4, createdAt: "2026-09-17T00:00:00.000Z", updatedAt: "2026-09-19T00:00:00.000Z"))
        #expect(edge.id == "e1")
        #expect(edge.sourceId == "a")
        #expect(edge.targetId == "b")
        #expect(edge.edgeType == "references")
        #expect(edge.properties == ["w": 1])
        #expect(edge.version == 4)
        #expect(edge.createdAt == "2026-09-17T00:00:00.000Z")
        #expect(edge.updatedAt == "2026-09-19T00:00:00.000Z")
    }

    @Test func propertiesTheCoreCannotReadAreRefusedRatherThanEmptied() {
        #expect(throws: DecodingError.self) {
            try Item(
                CoreItem(
                    id: "n1", type: "core.note", propertiesJson: "[1,2]", state: .active, tier: nil, version: 1,
                    schemaVersion: 1, source: "device", sourceId: nil, occurredAt: "", createdAt: "",
                    updatedAt: "", tags: []))
        }
    }

    @Test func aDraftAndAnEditCrossWhole() throws {
        let draft = try Draft(
            type: "core.note", properties: ["title": "t"], tags: ["x"], tier: .feed, id: "n9", source: "notes",
            sourceId: "a.md", occurredAt: "2026-09-18T00:00:00Z", baseVersion: 7
        ).core()
        #expect(draft.type == "core.note")
        #expect(try Properties.object(draft.propertiesJson) == ["title": "t"])
        #expect(draft.tags == ["x"])
        #expect(draft.tier == .feed)
        #expect(draft.id == "n9")
        #expect(draft.source == "notes")
        #expect(draft.sourceId == "a.md")
        #expect(draft.occurredAt == "2026-09-18T00:00:00Z")
        #expect(draft.baseVersion == 7)
        let edit = try Edit(properties: ["title": "u"], baseVersion: 4, sourceId: "b.md").core()
        #expect(edit.baseVersion == 4)
        #expect(edit.sourceId == "b.md")
        #expect(try Properties.object(edit.propertiesJson) == ["title": "u"])
    }

    @Test func filtersCrossWhole() {
        let list = ListFilters(
            type: "core.note", state: .archived, allStates: true, tier: .library, tags: ["a"],
            occurredAfter: "2026-01-01T00:00:00Z", occurredBefore: "2026-02-01T00:00:00Z", limit: 5, offset: 2
        ).core
        #expect(list.type == "core.note")
        #expect(list.state == .archived)
        #expect(list.allStates)
        #expect(list.tier == .library)
        #expect(list.tags == ["a"])
        #expect(list.occurredAfter == "2026-01-01T00:00:00Z")
        #expect(list.occurredBefore == "2026-02-01T00:00:00Z")
        #expect(list.limit == 5)
        #expect(list.offset == 2)
        let search = SearchFilters(type: "core.file", state: .active, allStates: false, tags: ["b", "c"]).core
        #expect(search.type == "core.file")
        #expect(search.state == .active)
        #expect(!search.allStates)
        #expect(search.tags == ["b", "c"])
    }

    @Test func aServerNeverPrintsItsKey() {
        let server = Server(url: URL(string: "https://marfa.example")!, key: "mk_secret")
        #expect(!"\(server)".contains("mk_secret"))
        #expect(!String(reflecting: server).contains("mk_secret"))
        // The witness: it does print the server.
        #expect("\(server)".contains("marfa.example"))
    }
}

@Suite struct Errors {
    /// Every case the core can throw, and the case and fields it arrives as.
    static let cases: [(CoreMarfaError, Marfa.MarfaError)] = [
        (.NotFound(code: "c", message: "m"), .notFound(code: "c", message: "m")),
        (.Unauthorized(code: "c", message: "m"), .unauthorized(code: "c", message: "m")),
        (.Forbidden(code: "c", message: "m"), .forbidden(code: "c", message: "m")),
        (.Validation(code: "c", message: "m"), .validation(code: "c", message: "m")),
        (.UnknownType(message: "m"), .unknownType(message: "m")),
        (
            .RateLimited(code: "c", message: "m", retryAfterSeconds: 9),
            .rateLimited(code: "c", message: "m", retryAfterSeconds: 9)
        ),
        (.Server(status: 503, code: "c", message: "m"), .server(status: 503, code: "c", message: "m")),
        (.Network(message: "m"), .network(message: "m")),
        (.Decoding(message: "m"), .decoding(message: "m")),
        (.Store(message: "m"), .store(message: "m")),
        (.NoServer(message: "m"), .noServer(message: "m")),
        (.NoCursor(message: "m"), .noCursor(message: "m")),
        (.HydrationIncomplete(message: "m"), .hydrationIncomplete(message: "m")),
        (
            .WrongSchema(expected: "8", found: "7", path: "p", message: "m"),
            .wrongSchema(expected: "8", found: "7", path: "p", message: "m")
        ),
        (.ReadingHandle(message: "m"), .readingHandle(message: "m")),
        (.CatchUpTooOld(minRetainedId: "5", message: "m"), .catchUpTooOld(minRetainedId: "5", message: "m")),
        (.StreamIncomplete(reason: "r", message: "m"), .streamIncomplete(reason: "r", message: "m")),
        (.WrongServer(expected: "a", got: "b", message: "m"), .wrongServer(expected: "a", got: "b", message: "m")),
        (.BytesAbsent(hash: "h", reason: "r", message: "m"), .bytesAbsent(hash: "h", reason: "r", message: "m")),
        (.Invalid(message: "m"), .invalid(message: "m")),
    ]

    @Test(arguments: cases)
    func eachCoreErrorArrivesAsItsOwnCase(core: CoreMarfaError, expected: Marfa.MarfaError) {
        #expect(throws: expected) { try translated { throw core } }
        #expect(expected.message == "m")
        #expect(expected.localizedDescription == "m")
    }

    /// The switch in `Marfa.MarfaError.init` is exhaustive, so a new core case
    /// fails the build; this keeps the list above from missing one it maps.
    @Test func everyCaseIsListedOnce() {
        #expect(Set(Self.cases.map { "\($0.1)".prefix { $0 != "(" } }).count == 20)
    }
}

@Suite struct Opening {
    @Test func aReadingOpenRefusesAPathWithNoStoreAndMakesNone() async throws {
        let path = temporaryStore()
        await #expect {
            _ = try await WorkingCopy.openReader(store: path)
        } throws: { error in
            if case Marfa.MarfaError.invalid = error { true } else { false }
        }
        #expect(!FileManager.default.fileExists(atPath: path.path))
        // The witness: once a writer has made it, the same open reads it.
        let writer = try await WorkingCopy.open(store: path)
        #expect(writer.handle == .writer)
        let reader = try await WorkingCopy.openReader(store: path)
        #expect(reader.handle == .reader)
    }

    @Test func aWriteRefusedByTheCoreArrivesAsItsError() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        await #expect {
            _ = try await copy.items.create(Draft(type: "core.note"))
        } throws: { error in
            if case Marfa.MarfaError.hydrationIncomplete = error { true } else { false }
        }
    }

    /// A second `open` of a store gets a reader, and watches the writer's
    /// saves as an `openReader` does rather than following a server.
    @Test func aSecondOpenerWatchesRatherThanFollows() async throws {
        let path = temporaryStore()
        let server = Server(url: URL(string: "http://127.0.0.1:9")!, key: "k")
        let writer = try await WorkingCopy.open(store: path, server: server)
        let second = try await WorkingCopy.open(store: path, server: server)
        #expect(writer.feed.source == .follow)
        #expect(second.handle == .reader)
        #expect(second.feed.source == .watch)
    }
}

@Suite struct Changes {
    func write(_ kind: WriteKind, item: String) -> QueuedWrite {
        QueuedWrite(
            id: "q", kind: kind, itemId: item, targetId: nil, edgeId: nil, namespace: nil, tag: "t", blob: nil,
            baseVersion: nil, idempotencyKey: "k", dependsOn: [], verdict: nil, answer: nil, refusals: 0,
            queuedAt: "", answeredAt: nil)
    }

    @Test func aWriteIsToldToEveryStreamHeldAndNoneAfterItEnds() async throws {
        let feed = Feed(core: try Core.open(path: temporaryStore().path, url: nil, key: nil), source: .none)
        let (first, firstContinuation) = AsyncStream<Marfa.Change>.makeStream()
        let (second, secondContinuation) = AsyncStream<Marfa.Change>.makeStream()
        let firstToken = try #require(feed.add(firstContinuation))
        _ = try #require(feed.add(secondContinuation))
        var firstHeard = first.makeAsyncIterator()
        var secondHeard = second.makeAsyncIterator()

        feed.announce(write(.addTag, item: "n1"))
        #expect(await firstHeard.next() == Marfa.Change(origin: .local(.addTag), itemId: "n1", edgeId: nil))
        #expect(await secondHeard.next() == Marfa.Change(origin: .local(.addTag), itemId: "n1", edgeId: nil))

        feed.remove(firstToken)
        firstContinuation.finish()
        feed.announce(write(.removeTag, item: "n2"))
        #expect(await secondHeard.next() == Marfa.Change(origin: .local(.removeTag), itemId: "n2", edgeId: nil))
        #expect(await firstHeard.next() == nil, "a stream that ended was still told")
    }

    @Test func endingTheIterationLetsGoOfTheStream() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let stream = copy.changes()
        #expect(copy.feed.count == 1)
        let listening = Task {
            for await _ in stream {}
        }
        listening.cancel()
        await listening.value
        try await eventually("the stream was let go") { copy.feed.count == 0 }
    }

    @Test func closingEndsEveryStreamAndRefusesNew() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        var held = copy.changes().makeAsyncIterator()
        copy.close()
        #expect(await held.next() == nil)
        var later = copy.changes().makeAsyncIterator()
        #expect(await later.next() == nil)
        #expect(copy.feed.count == 0)
    }

    /// A follow the core refuses, here for want of a hydration, is told to
    /// every stream, and local writes go on being told after it.
    @Test func aFollowThatStopsIsToldAndLocalWritesGoOn() async throws {
        let copy = try await WorkingCopy.open(
            store: temporaryStore(), server: Server(url: URL(string: "http://127.0.0.1:9")!, key: "k"))
        var heard = copy.changes().makeAsyncIterator()
        let stopped = await heard.next()
        guard case .stopped(.noCursor) = stopped?.origin else {
            Issue.record("the refused follow was not told: \(String(describing: stopped))")
            return
        }
        #expect(!copy.feed.isRunning)
        copy.feed.announce(write(.addTag, item: "n1"))
        #expect(await heard.next()?.origin == .local(.addTag))
    }
}
