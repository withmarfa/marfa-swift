import Foundation
import Marfa
import Observation

@MainActor @Observable
final class Model {
    let configuration: Configuration
    private(set) var copy: WorkingCopy?
    private(set) var notes: LiveQuery<Rows<Item>>?
    private(set) var queued: LiveQuery<[QueuedWrite]>?
    private(set) var message = ""
    var searchText = "" {
        didSet { notes?.reading = noteReading }
    }

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func open() async {
        guard copy == nil, configuration.scenario == nil else { return }
        do {
            let opened = try await WorkingCopy.open(store: configuration.store, server: configuration.server)
            copy = opened
            notes = LiveQuery(opened, reading: noteReading)
            queued = LiveQuery(opened, reading: .queue)
        } catch {
            message = error.localizedDescription
        }
    }

    private var noteReading: Reading<Rows<Item>> {
        searchText.isEmpty
            ? .list(ListFilters(types: ["core.note"], tier: .feed))
            : .search(searchText, filters: SearchFilters(types: ["core.note"]))
    }

    /// Whether the notes stopped following the copy, so they need a refresh to start again.
    var hasEnded: Bool {
        if case .ended = notes?.following { return true }
        return false
    }

    /// What the bottom of the window says: a failure the queries met, else the last thing done.
    var status: String {
        switch notes?.following {
        case .stopped(let error):
            return "no longer following the server: \(error.message)"
        case .ended(let error):
            let why = error.map { ": \($0.message)" } ?? ""
            return "the notes no longer update\(why). Refresh to start again."
        case .live, nil:
            break
        }
        if let failure = notes?.error ?? queued?.error { return failure.localizedDescription }
        return message
    }

    func refresh() async {
        await notes?.refresh()
        await queued?.refresh()
    }

    func hydrate() async {
        guard let copy, configuration.server != nil else { return }
        while !Task.isCancelled {
            do {
                if try await copy.status().hydration != .complete {
                    _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
                    message = "hydrated"
                }
                return
            } catch {
                message = "not hydrated yet, trying again: \(error.localizedDescription)"
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func perform(_ what: String, _ work: (WorkingCopy) async throws -> Void) async {
        guard let copy else { return }
        do {
            try await work(copy)
            message = what
        } catch {
            message = "\(what): \(error.localizedDescription)"
        }
    }

    func create(title: String) async {
        await perform("created") { copy in
            _ = try await copy.items.create(
                Draft(type: "core.note", properties: ["title": .string(title), "body": ""], tier: .feed))
        }
    }

    func rename(_ note: Item, to title: String) async {
        await perform("edited") { copy in
            _ = try await copy.items.update(
                note.id, Edit(properties: ["title": .string(title)], baseVersion: note.version))
        }
    }

    func toggleFavorite(_ note: Item) async {
        await perform("tagged") { copy in
            if note.tags.contains("favorite") {
                _ = try await copy.tags.remove("favorite", from: note.id)
            } else {
                _ = try await copy.tags.add("favorite", to: note.id)
            }
        }
    }

    func link(_ source: Item, to target: Item) async {
        await perform("linked") { copy in
            _ = try await copy.edges.create(from: source.id, to: target.id, type: "references")
        }
    }

    func attach(_ file: URL, to note: Item) async {
        await perform("attached") { copy in
            _ = try await copy.items.attach(to: note.id, file: file)
        }
    }

    func delete(_ note: Item) async {
        await perform("deleted") { copy in _ = try await copy.items.delete(note.id) }
    }

    func drain() async {
        await perform("drained") { copy in _ = try await copy.queue.drain() }
    }
}
