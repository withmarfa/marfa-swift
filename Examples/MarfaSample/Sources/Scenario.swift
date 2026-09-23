import Foundation
import Marfa

/// The sample run unattended, one phase per launch, printing each step and
/// checking what it expects: `hydrate` with the server up, `write` with it
/// stopped, `drain` once it is back, and `catch-up` after a change made
/// elsewhere.
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
                    Draft(type: "core.note", properties: ["title": "Sample first", "body": "written offline"], tier: .feed))
                let second = try await copy.items.create(
                    Draft(type: "core.note", properties: ["title": "Sample second", "body": "the other end"], tier: .feed))
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
                let offline = try await copy.queue.drain()
                print("drain with the server away: sent \(offline.sent), answered \(offline.verdicts.filter { $0.verdict != nil }.count)")
                expect(offline.verdicts.allSatisfy { $0.verdict == nil }, "a drain with the server away answered a write")

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
                let report = try await copy.catchUp()
                print("caught up: applied \(report.applied)")
                let notes = try await copy.items.list(ListFilters(type: "core.note", tier: .feed))
                expect(notes.contains { $0.title == "Made by the binary" }, "the change made elsewhere did not arrive")

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
}
