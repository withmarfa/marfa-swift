import Foundation
import MarfaCore
import Synchronization

/// A core that keeps items, edges, types and a queue in memory.
///
/// It runs no Rust, opens no store and reaches no server. What it serves is
/// stated by `FakeCopy`; every other call of the core throws
/// `FakeCopyError.unsupported`.
final class InMemoryCore: CoreProtocol, Sendable {
    struct Entry {
        var write: QueuedWrite
        var inQueue = true
    }

    struct State {
        var items: [String: Item] = [:]
        var edges: [String: Edge] = [:]
        var edgeOrder: [String: Int] = [:]
        var givenItemTypes: [String: ItemType] = [:]
        var edgeTypes: [String: EdgeType] = [:]
        var declared: [String: JsonObject] = [:]
        var entries: [Entry] = []
        /// Items made through the copy, which the core holds as pinned.
        var made: Set<String> = []
        var verdict: @Sendable (QueuedWrite) -> Verdict? = { _ in .accepted }
    }

    let state: Mutex<State>

    init(items: [Item], edges: [Edge], itemTypes: [ItemType], edgeTypes: [EdgeType]) {
        var state = State()
        for item in items { state.items[item.id] = item }
        for edge in edges { state.add(edge) }
        for type in itemTypes { state.givenItemTypes[type.id] = type }
        for type in edgeTypes { state.edgeTypes[type.id] = type }
        self.state = Mutex(state)
    }

    var writes: [QueuedWrite] { state.withLock { $0.entries.map(\.write) } }

    func chooseVerdicts(_ verdict: @escaping @Sendable (QueuedWrite) -> Verdict?) {
        state.withLock { $0.verdict = verdict }
    }

    func heldHandle() -> Handle { .writer }

    func status() throws -> Status {
        state.withLock { state in
            Status(
                serverOrigin: nil, instanceId: nil, sliceTypes: [], sliceTier: nil, sliceEdgeTypes: [],
                pinned: state.made.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }, eventCursor: nil,
                hydration: .never, items: UInt64(state.items.count), edges: UInt64(state.edges.count),
                catalogVersion: nil)
        }
    }

    // MARK: Reads

    func get(id: String) throws -> Item? {
        state.withLock { state in state.items[id].flatMap { $0.state == .trashed ? nil : $0 } }
    }

    func list(filters: ListFilters, sort: Sort) throws -> [Item] {
        if filters.filter != nil { throw FakeCopyError.unsupported(call: "items.list(filter:)") }
        if filters.occurredAfter != nil || filters.occurredBefore != nil {
            throw FakeCopyError.unsupported(call: "items.list(occurredAfter:occurredBefore:)")
        }
        return try state.withLock { state in
            let types = state.resolvedItemTypes()
            let root = try filters.type.flatMap { try Self.root(of: $0) }
            let beneath = filters.beneath.map { state.reached(from: $0) }
            var found = state.items.values.filter { item in
                if let root {
                    guard Self.reaches(item.type, root, in: types) else { return false }
                }
                if let state = filters.state {
                    guard item.state == state else { return false }
                } else if !filters.allStates {
                    guard item.state == .active else { return false }
                }
                if let tier = filters.tier, item.tier != tier { return false }
                if let beneath, !beneath.contains(item.id) { return false }
                return filters.tags.allSatisfy(item.tags.contains)
            }
            found.sort { Self.precedes($0, $1, by: sort) }
            let offset = Int(filters.offset ?? 0)
            guard offset < found.count else { return [] }
            found.removeFirst(offset)
            if let limit = filters.limit { found = Array(found.prefix(Int(limit))) }
            return found
        }
    }

    func edgesFrom(id: String) throws -> [Edge] {
        state.withLock { $0.edgesInOrder.filter { $0.sourceId == id } }
    }

    func edgesTo(id: String) throws -> [Edge] {
        state.withLock { $0.edgesInOrder.filter { $0.targetId == id } }
    }

    func edgesOfType(edgeType: String) throws -> [Edge] {
        state.withLock { $0.edgesInOrder.filter { $0.edgeType == edgeType } }
    }

    private static func root(of name: String) throws -> String? {
        guard name != "*" else { return nil }
        guard Declaring.isTypePattern(name) else {
            throw Refuse.validation("validation_error", "Invalid type identifier: \(name)")
        }
        return name.hasSuffix(".*") ? String(name.dropLast(2)) : name
    }

    /// A type reaches `root` by its name or by a declared parent.
    private static func reaches(_ type: String, _ root: String, in types: [String: ItemType]) -> Bool {
        var current: String? = type
        var steps = 0
        while let name = current, steps < 64 {
            if name == root || name.hasPrefix(root + ".") { return true }
            current = types[name]?.parent
            steps += 1
        }
        return false
    }

    private static func precedes(_ lhs: Item, _ rhs: Item, by sort: Sort) -> Bool {
        let (left, right): (String, String) =
            switch sort.field {
            case .createdAt: (lhs.createdAt, rhs.createdAt)
            case .updatedAt: (lhs.updatedAt, rhs.updatedAt)
            case .occurredAt: (lhs.occurredAt, rhs.occurredAt)
            }
        let ordered = left == right ? lhs.id < rhs.id : left < right
        let reversed = left == right ? lhs.id > rhs.id : left > right
        return sort.direction == .ascending ? ordered : reversed
    }
}

extension InMemoryCore.State {
    mutating func add(_ edge: Edge) {
        if edgeOrder[edge.id] == nil { edgeOrder[edge.id] = edgeOrder.count }
        edges[edge.id] = edge
    }

    /// Oldest first.
    var edgesInOrder: [Edge] {
        edges.values.sorted { (edgeOrder[$0.id] ?? 0) < (edgeOrder[$1.id] ?? 0) }
    }

    /// An item and every item it reaches along `parent-of` edges.
    func reached(from id: String) -> Set<String> {
        var seen: Set<String> = [id]
        var queue = [id]
        while let next = queue.popLast() {
            for edge in edges.values where edge.edgeType == "parent-of" && edge.sourceId == next {
                if seen.insert(edge.targetId).inserted { queue.append(edge.targetId) }
            }
        }
        return seen
    }
}
