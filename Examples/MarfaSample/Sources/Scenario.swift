import Foundation
import Marfa

/// The sample run unattended, one phase per launch, printing each step and
/// checking what it expects: `hydrate` with the server up, `write` with it
/// stopped, `drain` once it is back, and `catch-up`, which makes a note
/// through a second working copy and reads it back through this one.
enum Scenario {
    static func run(_ phase: String, configuration: Configuration) async -> Bool {
        var passed = true
        func expect(_ held: Bool, _ expectation: String) {
            if !held {
                print("scenario failed: \(expectation)")
                passed = false
            }
        }
        do {
            let copy = try await WorkingCopy.open(store: configuration.store, server: configuration.server)
            switch phase {
            case "hydrate":
                let report = try await copy.hydrate(types: ["core.note"], tier: .feed)
                print("hydrated \(report.items) item(s) at feed")

            case "write":
                let first = try await copy.items.create(
                    Draft(
                        type: "core.note", properties: ["title": "Sample first", "body": "written offline"], tier: .feed
                    ))
                let second = try await copy.items.create(
                    Draft(
                        type: "core.note", properties: ["title": "Sample second", "body": "the other end"], tier: .feed)
                )
                let firstId = first.itemId ?? ""
                let held = try await copy.items.get(firstId)
                _ = try await copy.items.update(
                    firstId, Edit(properties: ["title": "Sample first, edited"], baseVersion: held?.version ?? 0))
                _ = try await copy.tags.add("favorite", to: firstId)
                _ = try await copy.edges.create(from: firstId, to: second.itemId ?? "", type: "references")
                let file = FileManager.default.temporaryDirectory.appending(path: "sample-attachment.txt")
                try Data("attached offline\n".utf8).write(to: file)
                _ = try await copy.items.attach(to: firstId, file: file)
                let queued = try await copy.queue.all()
                print("queued \(queued.count) write(s)")
                for write in queued { print("  \(write.kind)  \(describe(write.verdict))") }
                // Two creates, the edit, the tag, the link, and the three
                // writes an attachment is.
                expect(queued.count == 8, "queued \(queued.count) writes, not 8")
                let offline = try await copy.queue.drain()
                let answered = offline.verdicts.filter { $0.verdict != nil }.count
                print("drain with the server away: sent \(offline.sent), answered \(answered)")
                expect(offline.sent > 0, "a drain with the server away tried nothing")
                expect(answered == 0, "a drain with the server away answered a write")
                // A write that waits on one still unanswered is held for it,
                // which is the only verdict a drain reaches with no server.
                let after = try await copy.queue.all()
                let waiting = after.filter { $0.verdict == .blocked(reason: .awaitingDependency) }.count
                print("held for an earlier write: \(waiting)")
                expect(
                    after.allSatisfy { $0.verdict == nil || $0.verdict == .blocked(reason: .awaitingDependency) },
                    "a write was answered with the server away")

            case "drain":
                let report = try await copy.queue.drain()
                for entry in report.verdicts { print("  \(entry.kind)  \(describe(entry.verdict))") }
                expect(!report.verdicts.isEmpty, "the drain sent nothing")
                expect(report.verdicts.allSatisfy { $0.verdict == .accepted }, "a write was not accepted")
                let notes = try await copy.items.list(ListFilters(type: "core.note", tier: .feed))
                let edited = notes.first { $0.title == "Sample first, edited" }
                print("notes: \(notes.map { "\($0.title ?? "-") v\($0.version)" })")
                expect(edited?.tags.contains("favorite") == true, "the edit lost its tag")

            case "catch-up":
                let title = "Made elsewhere \(UUID())"
                try await makeElsewhere(title, configuration: configuration)
                let report = try await copy.catchUp()
                print("caught up: applied \(report.applied)")
                let notes = try await copy.items.list(ListFilters(type: "core.note", tier: .feed))
                expect(notes.contains { $0.title == title }, "the change made elsewhere did not arrive")

            default:
                print("name a phase: hydrate, write, drain or catch-up")
                return false
            }
        } catch {
            print("scenario failed: \(error)")
            return false
        }
        print("scenario \(phase): \(passed ? "passed" : "failed")")
        return passed
    }

    /// A note made through a working copy of its own beside this one's
    /// store, and sent.
    static func makeElsewhere(_ title: String, configuration: Configuration) async throws {
        let store = configuration.store.deletingLastPathComponent().appending(path: "elsewhere-\(UUID()).sqlite")
        let elsewhere = try await WorkingCopy.open(store: store, server: configuration.server)
        _ = try await elsewhere.hydrate(types: ["core.note"], tier: .feed)
        _ = try await elsewhere.items.create(
            Draft(type: "core.note", properties: ["title": .string(title), "body": "elsewhere"], tier: .feed))
        let sent = try await elsewhere.queue.drain()
        guard !sent.verdicts.isEmpty, sent.verdicts.allSatisfy({ $0.verdict == .accepted }) else {
            throw MarfaError.invalid(message: "the note made elsewhere was not accepted: \(sent.verdicts)")
        }
        print("made \(title) elsewhere")
    }
}
