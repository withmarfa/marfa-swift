import Foundation
import Testing

@testable import Marfa

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveBodyLinks {
        static func answers(_ report: DrainReport) -> [String: Verdict?] {
            Dictionary(report.verdicts.map { ($0.id, $0.verdict) }, uniquingKeysWith: { first, _ in first })
        }

        @Test func anEmbeddedFileIsOneEdgeTheServerHoldsAndALinkResolvesByTheServersLookup() async throws {
            let copy = try await Live.hydrated()
            let suffix = UUID().uuidString
            let unique = "Unique \(suffix)"
            let twin = "Twin \(suffix)"
            let absent = "Absent \(suffix)"
            let target = try await copy.items.create(Live.note(unique))
            let twins = [
                try await copy.items.create(Live.note(twin)), try await copy.items.create(Live.note(twin)),
            ]
            let host = try await copy.items.create(Live.note("Host \(suffix)"))
            var writes = [target] + twins + [host]
            let name = "embedded-\(suffix).mov"
            let embedded = try await copy.items.embed(
                file: try Live.file("bytes \(suffix)", named: name), in: host.itemId ?? "")
            writes += [embedded.attached.upload, embedded.attached.item, embedded.attached.edge, embedded.body]
            let hostId = try #require(host.itemId)
            let fileId = try #require(embedded.attached.item.itemId)

            // The server holds the notes only once they are answered, so the link is written after.
            var answered = Self.answers(try await copy.queue.drain())
            for write in writes {
                #expect(
                    answered[write.id] == .accepted,
                    "\(write.kind) was answered \(String(describing: answered[write.id]))")
            }
            let current = try #require(try await copy.items.get(hostId))
            let body = try #require(current.body)
            let linked = body + "\n\n[[\(unique)|shown]] [[\(twin)]] [[\(absent)]]"
            let edit = try await copy.items.update(
                hostId, Edit(.merge(["body": .string(linked)]), baseVersion: current.version))
            answered = Self.answers(try await copy.queue.drain())
            #expect(answered[edit.id] == .accepted)

            let found = try await copy.items.links(in: hostId)
            #expect(found.embeds == [BodyName(text: "![[\(name)]]", name: name, target: .item(id: fileId))])
            #expect(found.links.map(\.name) == [unique, twin, absent])
            #expect(found.links.map(\.text) == ["[[\(unique)|shown]]", "[[\(twin)]]", "[[\(absent)]]"])
            #expect(found.links[0].target == .item(id: try #require(target.itemId)))
            #expect(found.links[1].target == .ambiguous)
            #expect(found.links[2].target == .missing)

            // The embed is the attach's own edge, and the server holds no second one.
            let fresh = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await fresh.hydrate(types: ["core.note"], tier: .feed, edgeTypes: ["attached-to"])
            let edges = try await fresh.edges.to(hostId).filter { $0.sourceId == fileId }
            #expect(edges.count == 1, "the embed made more than one edge: \(edges)")
            await fresh.close()
            await copy.close()
        }
    }
}
