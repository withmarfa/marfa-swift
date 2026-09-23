import Foundation
import Marfa
import Observation

/// The notes one working copy holds, the queue behind them, and what the
/// person last did.
@MainActor @Observable
final class Model {
    let configuration: Configuration
    private(set) var copy: WorkingCopy?
    private(set) var notes: [Item] = []
    private(set) var queued: [QueuedWrite] = []
    private(set) var message = ""
    var query = "" {
        didSet { Task { await refresh() } }
    }

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func open() async {
        guard copy == nil, configuration.scenario == nil else { return }
        do {
            let copy = try await WorkingCopy.open(store: configuration.store, server: configuration.server)
            self.copy = copy
            if try await copy.status().hydration != .complete, configuration.server != nil {
                _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
            }
            await refresh()
            for await _ in copy.changes() {
                await refresh()
            }
        } catch {
            message = "\(error)"
        }
    }

    func refresh() async {
        guard let copy else { return }
        do {
            if query.isEmpty {
                notes = try await copy.items.list(ListFilters(type: "core.note", tier: .feed))
            } else {
                notes = try await copy.search(query, filters: SearchFilters(type: "core.note")).map(\.item)
            }
            queued = try await copy.queue.all()
        } catch {
            message = "\(error)"
        }
    }

    func perform(_ what: String, _ work: (WorkingCopy) async throws -> Void) async {
        guard let copy else { return }
        do {
            try await work(copy)
            message = what
        } catch {
            message = "\(what): \(error)"
        }
        await refresh()
    }

    func create(title: String) async {
        await perform("created") { copy in
            _ = try await copy.items.create(
                Draft(type: "core.note", properties: ["title": .string(title), "body": ""], tier: .feed))
        }
    }

    func rename(_ note: Item, to title: String) async {
        await perform("edited") { copy in
            _ = try await copy.items.update(note.id, Edit(properties: ["title": .string(title)], baseVersion: note.version))
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
