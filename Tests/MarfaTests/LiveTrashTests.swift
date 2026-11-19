import Foundation
import Testing

@testable import Marfa

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveTrash {
        private func task(_ copy: WorkingCopy, _ title: String) async throws -> String {
            try #require(
                try await copy.items.create(
                    Draft(type: "core.task", properties: ["title": .string(title)], tier: .library)
                ).itemId)
        }

        private func hydrated() async throws -> WorkingCopy {
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await copy.hydrate(types: ["core.task"], tier: .library, edgeTypes: ["parent-of"])
            return copy
        }

        /// A parent with one child, and a lone item, all sent.
        private func family(_ copy: WorkingCopy) async throws -> (parent: String, child: String, lone: String) {
            let parent = try await task(copy, "parent \(UUID())")
            let child = try await task(copy, "child \(UUID())")
            let lone = try await task(copy, "lone \(UUID())")
            _ = try await copy.edges.create(from: parent, to: child, type: "parent-of")
            let drained = try await copy.queue.drain()
            #expect(drained.verdicts.allSatisfy { $0.verdict == .accepted }, "\(drained.verdicts)")
            return (parent, child, lone)
        }

        @Test func severalItemsAreTrashedTogetherWithWhatOneOfThemTakesAndTheCopyShowsIt() async throws {
            let copy = try await hydrated()
            let (parent, child, lone) = try await family(copy)

            let preview = try await copy.items.previewTrash(ids: [parent, lone])
            #expect(preview.items.map(\.id) == [parent, lone])
            #expect(preview.items[0].takes.map(\.id) == [child], "\(preview)")
            #expect(preview.items[1].takes.isEmpty)
            #expect(preview.count == 3)

            let report = try await copy.items.trash(preview)
            #expect(report.settled, "\(String(describing: report.behind))")
            for id in [parent, child, lone] {
                #expect(try await copy.items.get(id) == nil, "\(id) is still shown after the trash")
            }
            let binned = try await copy.items.bin(limit: 100).items.map(\.id)
            #expect(Set([parent, child, lone]).isSubset(of: Set(binned)), "the server's bin holds the trash")
            await copy.close()
        }

        @Test func aPreviewThatWentStaleIsRefusedAndNothingIsTrashed() async throws {
            let copy = try await hydrated()
            let (parent, _, lone) = try await family(copy)
            let preview = try await copy.items.previewTrash(ids: [parent, lone])

            // Another child joins the parent after the preview.
            let late = try await task(copy, "late \(UUID())")
            _ = try await copy.edges.create(from: parent, to: late, type: "parent-of")
            _ = try await copy.queue.drain()

            await #expect {
                _ = try await copy.items.trash(preview)
            } throws: { error in
                if case .trashPlanChanged? = error as? MarfaError { true } else { false }
            }
            #expect(try await copy.items.get(parent) != nil)
            #expect(try await copy.items.get(lone) != nil)

            let fresh = try await copy.items.previewTrash(ids: [parent, lone])
            #expect(fresh.count == 4, "the new preview takes the late child too")
            let report = try await copy.items.trash(fresh)
            #expect(report.settled)
            await copy.close()
        }

        @Test func aWriteStillWaitingForAnItemRefusesTheTrashAndStaysQueued() async throws {
            let copy = try await hydrated()
            let (parent, _, lone) = try await family(copy)
            let preview = try await copy.items.previewTrash(ids: [parent, lone])
            let held = try #require(try await copy.items.get(lone))
            let waiting = try await copy.items.update(
                lone, Edit(properties: ["title": "edited"], baseVersion: held.version))

            await #expect {
                _ = try await copy.items.trash(preview)
            } throws: { error in
                guard case .invalid(let message)? = error as? MarfaError else { return false }
                return message.contains(waiting.id)
            }
            let unanswered = try await copy.queue.all().filter { $0.verdict == nil }
            #expect(unanswered.map(\.id) == [waiting.id], "the person's edit stays queued")
            #expect(try await copy.items.get(parent) != nil)
            await copy.close()
        }
    }
}
