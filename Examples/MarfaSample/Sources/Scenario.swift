import Foundation
import Marfa

/// One phase per launch.
///
/// CI stops the server between `hydrate` and `write` and starts it again for
/// `drain`.
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
                _ = try await copy.items.create(
                    Draft(type: "core.note", properties: ["title": "Sample kept", "body": "sent online"], tier: .feed))
                let sent = try await copy.queue.drain()
                print("sent online: \(sent.verdicts.map { describe($0.verdict) })")
                expect(sent.verdicts.map(\.verdict) == [.accepted], "the note sent online was not accepted")
                // So the queue the write phase reads holds only what it queues.
                _ = try await copy.queue.forgetAnswered()

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
                // The first edit does not move the held version while it is
                // unanswered, so both are based on the same one.
                let notes = try await copy.items.list(ListFilters(type: "core.note", tier: .feed))
                guard let kept = notes.first(where: { $0.title == "Sample kept" }) else {
                    expect(false, "the note sent online is not held")
                    break
                }
                var edits: [QueuedWrite] = []
                for body in ["edited offline once", "edited offline twice"] {
                    let read = try await copy.items.get(kept.id)
                    edits.append(
                        try await copy.items.update(
                            kept.id, Edit(properties: ["body": .string(body)], baseVersion: read?.version ?? 0)))
                }
                expect(edits.count == 2 && edits[1].follows == edits[0].id, "the second edit does not follow the first")
                try await checkSearch(first: firstId, kept: kept.id, in: copy, expect)
                let queued = try await copy.queue.all()
                print("queued \(queued.count) write(s)")
                for write in queued { print("  \(write.kind)  \(describe(write))") }
                expect(queued.count == 10, "queued \(queued.count) writes, not 10")
                let offline = try await copy.queue.drain()
                let answered = offline.verdicts.filter { $0.verdict != nil }.count
                print("drain with the server away: undelivered \(offline.undelivered), answered \(answered)")
                expect(offline.undelivered > 0 && offline.unavailable != nil, "the drain did not report the outage")
                expect(answered == 0, "a drain with the server away answered a write")
                let after = try await copy.queue.all()
                let waiting = after.filter(\.waiting).count
                print("held for an earlier write: \(waiting)")
                expect(waiting > 0, "no write waited on an earlier one")
                expect(after.allSatisfy { $0.verdict == nil }, "a write was answered with the server away")

            case "drain":
                let report = try await copy.queue.drain()
                for entry in report.verdicts { print("  \(entry.kind)  \(describe(entry.verdict))") }
                expect(report.verdicts.count == 10, "the drain sent \(report.verdicts.count) writes, not 10")
                expect(report.held == 0, "the drain held \(report.held) write(s) back")
                expect(report.verdicts.allSatisfy { $0.verdict == .accepted }, "a write was not accepted")
                let notes = try await copy.items.list(ListFilters(type: "core.note", tier: .feed))
                print("notes: \(notes.map { "\($0.title ?? "-") v\($0.version)" })")
                guard let first = notes.first(where: { $0.title == "Sample first, edited" }),
                    let second = notes.first(where: { $0.title == "Sample second" })
                else {
                    expect(false, "the two notes the write phase made are not both held")
                    break
                }
                expect(first.tags.contains("favorite"), "the edit lost its tag")
                let links = try await copy.edges.from(first.id).filter { $0.edgeType == "references" }
                print("links from the first note: \(links.map(\.targetId))")
                expect(links.map(\.targetId) == [second.id], "the link does not run from the first note to the second")
                try await checkAttachment(on: first, in: copy, expect)
                let kept = notes.filter { $0.title == "Sample kept" }
                print("the kept note: \(kept.map { "\($0.properties["body"]?.string ?? "-") v\($0.version)" })")
                expect(
                    kept.map { $0.properties["body"]?.string } == ["edited offline twice"],
                    "the kept note does not hold its second edit, alone")
                if let keptId = kept.first?.id {
                    try await checkSearch(first: first.id, kept: keptId, in: copy, expect)
                }

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

    static func checkAttachment(
        on note: Item, in copy: WorkingCopy, _ expect: (Bool, String) -> Void
    ) async throws {
        let files = try await copy.items.list(ListFilters(type: "core.file"))
        guard let file = files.first(where: { $0.title == "sample-attachment.txt" }),
            let hash = file.properties["blob_ref"]?.string
        else {
            expect(false, "the attached file is not held with its bytes named: \(files.map(\.title))")
            return
        }
        let attachedTo = try await copy.edges.from(file.id).filter { $0.edgeType == "attached-to" }.map(\.targetId)
        print("the file is attached to: \(attachedTo)")
        expect(attachedTo == [note.id], "the file is not attached to the first note")
        let bytes = try Data(contentsOf: try await copy.blobs.get(hash))
        expect(bytes == Data("attached offline\n".utf8), "the file's bytes are not the ones attached")
    }

    static func checkSearch(
        first: String, kept: String, in copy: WorkingCopy, _ expect: (Bool, String) -> Void
    ) async throws {
        let notes = try await copy.search("offline", filters: SearchFilters(type: "core.note"))
        let favorites = try await copy.search("offline", filters: SearchFilters(type: "core.note", tags: ["favorite"]))
        let titles = { (hits: [SearchHit]) in hits.map { $0.item.title ?? "-" } }
        print("searched for offline: \(titles(notes)), narrowed to favorites: \(titles(favorites))")
        expect(Set([first, kept]).isSubset(of: Set(notes.map(\.item.id))), "a search of the notes did not find both")
        expect(favorites.map(\.item.id) == [first], "a search narrowed to favorites did not find the first note alone")
    }

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
