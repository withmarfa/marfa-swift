import Foundation
import Testing

@testable import Marfa

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveFiles {
        @Test func anAttachedFileShowsItsSizeBeforeTheDrainAndTheServersAfter() async throws {
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await copy.hydrate(types: ["core.note", "core.file"], tier: .feed)
            let note = try #require(try await copy.items.create(Live.note("holds a file \(UUID())")).itemId)
            let text = "a file of known length \(UUID())"
            let attached = try await copy.items.attach(to: note, file: try Live.file(text))
            let file = try #require(attached.item.itemId)
            let length = Int64(Data(text.utf8).count)

            let queued = try #require(try await copy.items.get(file))
            #expect(queued.properties["size_bytes"]?.integer == length, "the copy shows no size before the drain")

            let drained = try await copy.queue.drain()
            #expect(drained.verdicts.map(\.verdict) == [.accepted, .accepted, .accepted, .accepted])
            let answered = try #require(try await copy.items.get(file))
            #expect(answered.properties["size_bytes"]?.integer == length)
            let served = try await Live.read("items/\(file)")
            #expect(served["item"]?.object?["properties"]?.object?["size_bytes"]?.integer == length)
        }
    }
}
