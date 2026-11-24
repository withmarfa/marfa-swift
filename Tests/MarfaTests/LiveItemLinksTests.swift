import Foundation
import Testing

@testable import Marfa

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveItemLinks {
        @Test func aSentItemAnswersItsLinksAndStillDoesOnceTrashed() async throws {
            let server = try #require(Live.server)
            let copy = try await Live.hydrated()
            let id = try #require(try await copy.items.create(Live.note("Links \(UUID())")).itemId)
            let drained = try await copy.queue.drain()
            #expect(drained.verdicts.allSatisfy { $0.verdict == .accepted }, "\(drained.verdicts)")
            let instance = try #require(try await Live.read("/")["instance_id"]?.string)

            let before = try await server.itemLinks(of: id)
            #expect(before.app.absoluteString == "marfa://\(instance)/\(id)")
            #expect(before.web.absoluteString.hasSuffix("/i/\(id)"), "\(before.web)")
            #expect(["http", "https"].contains(before.web.scheme))

            let report = try await copy.items.trash(try await copy.items.previewTrash(ids: [id]))
            #expect(report.settled, "\(String(describing: report.behind))")
            #expect(try await server.itemLinks(of: id) == before, "the links of a trashed item changed")
            await copy.close()
        }

        @Test func anItemTheServerDoesNotHoldIsNotFound() async throws {
            let server = try #require(Live.server)
            do {
                _ = try await server.itemLinks(of: Live.uuidV7())
                Issue.record("an unknown item answered links")
            } catch .notFound(let code, _, _) {
                #expect(code == "item_not_found")
            }
        }
    }
}
