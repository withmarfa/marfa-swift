import Foundation
import Marfa
import Observation

@MainActor @Observable
final class Model {
    let configuration: Configuration
    private(set) var copy: WorkingCopy?
    private(set) var notes: LiveQuery<[Item]>?
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

    private var noteReading: Reading<[Item]> {
        searchText.isEmpty
            ? .list(ListFilters(type: "core.note", tier: .feed))
            : .search(searchText, filters: SearchFilters(type: "core.note"))
    }

    /// What the bottom of the window says: a failure the queries met, else the last thing done.
    var status: String {
        if case .stopped(let error) = notes?.following {
            return "no longer following the server: \(error.message)"
        }
        if let failure = notes?.error ?? queued?.error { return failure.localizedDescription }
        return message
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
