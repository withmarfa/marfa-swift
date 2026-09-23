import Foundation
import MarfaCore
import Testing

@testable import Marfa

@Suite struct Values {
    @Test func jsonRoundTripsThroughTheTextTheCoreTakes() throws {
        let properties: [String: JSONValue] = [
            "title": "A note", "count": 3, "ratio": 0.5, "done": false, "none": nil,
            "tags": ["a", "b"], "nested": ["key": "value"],
        ]
        #expect(try Properties.object(Properties.text(properties)) == properties)
    }

    @Test func anItemCrossesWithItsPropertiesRead() throws {
        let item = try Item(
            CoreItem(
                id: "n1", type: "core.note", propertiesJson: #"{"title":"Heron","body":"b"}"#, state: .active,
                tier: .feed, version: 2, schemaVersion: 1, source: "device", sourceId: nil,
                occurredAt: "2026-09-18T00:00:00.000Z", createdAt: "2026-09-18T00:00:00.000Z",
                updatedAt: "2026-09-18T00:00:00.000Z", tags: ["favorite"]))
        #expect(item.title == "Heron")
        #expect(item.properties["body"] == "b")
        #expect(item.tags == ["favorite"])
        #expect(item.version == 2)
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
        let draft = try Draft(type: "core.note", properties: ["title": "t"], tags: ["x"], tier: .feed).core()
        #expect(draft.type == "core.note")
        #expect(try Properties.object(draft.propertiesJson) == ["title": "t"])
        #expect(draft.tags == ["x"])
        #expect(draft.tier == .feed)
        let edit = try Edit(properties: ["title": "u"], baseVersion: 4).core()
        #expect(edit.baseVersion == 4)
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
}

@Suite struct Opening {
    @Test func aReadingOpenRefusesAPathWithNoStoreAndMakesNone() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "marfa-\(UUID()).sqlite")
        await #expect {
            _ = try await WorkingCopy.openReader(store: path)
        } throws: { error in
            if case MarfaError.Invalid = error { true } else { false }
        }
        #expect(!FileManager.default.fileExists(atPath: path.path))
        // The witness: once a writer has made it, the same open reads it.
        let writer = try await WorkingCopy.open(store: path)
        #expect(writer.handle == .writer)
        let reader = try await WorkingCopy.openReader(store: path)
        #expect(reader.handle == .reader)
    }

    @Test func aWriteRefusedByTheCoreArrivesAsItsError() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "marfa-\(UUID()).sqlite")
        let copy = try await WorkingCopy.open(store: path)
        await #expect {
            _ = try await copy.items.create(Draft(type: "core.note"))
        } throws: { error in
            if case MarfaError.HydrationIncomplete = error { true } else { false }
        }
    }
}

@Suite struct Changes {
    @Test func aWriteIsToldToEveryStreamHeldAndNoneAfterItEnds() async throws {
        let observers = Observers()
        var first: AsyncStream<Marfa.Change>.Continuation!
        let stream = AsyncStream<Marfa.Change> { first = $0 }
        let token = observers.add(first)
        let write = QueuedWrite(
            id: "q", kind: .addTag, itemId: "n1", targetId: nil, edgeId: nil, namespace: nil, tag: "t", blob: nil,
            baseVersion: nil, idempotencyKey: "k", dependsOn: [], verdict: nil, answer: nil, refusals: 0,
            queuedAt: "", answeredAt: nil)
        observers.announce(write)
        var iterator = stream.makeAsyncIterator()
        let change = await iterator.next()
        #expect(change == Marfa.Change(origin: .local(.addTag), itemId: "n1", edgeId: nil))
        observers.remove(token)
        #expect(observers.count == 0)
    }

    @Test func endingTheIterationLetsGoOfTheStream() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "marfa-\(UUID()).sqlite")
        let copy = try await WorkingCopy.open(store: path)
        let listening = Task {
            for await _ in copy.changes() {}
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(copy.observers.count == 1)
        listening.cancel()
        await listening.value
        #expect(copy.observers.count == 0)
    }
}
