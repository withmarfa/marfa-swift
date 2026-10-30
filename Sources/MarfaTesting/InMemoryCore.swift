#if DEBUG
import Foundation
import MarfaCore
import Synchronization

/// A core that keeps items, edges, types and a queue in memory.
///
/// It runs no Rust, opens no store and reaches no server. What it serves is
/// stated by `FakeCopy`; every other call of the core throws
/// `FakeCopyError.unsupported`.
final class InMemoryCore: CoreProtocol, Sendable {
    enum TagChange {
        case add(String)
        case remove(String)
        case replace([String])
    }

    /// What a write does to the rows, so the rows can be worked out again from
    /// the seed and the writes that were not refused.
    enum Effect {
        case none
        /// A create, with the row as it was made and no tags: each tag is its own write.
        case made(Item, edges: [Edge])
        case edit(
            properties: JsonObject, replacing: Bool, type: String?, tier: Tier?, sourceId: String?, occurredAt: String?)
        case state(ItemState)
        case tags(TagChange)
        case madeEdge(Edge)
        case editEdge(properties: JsonObject, source: String?, target: String?)
        case removedEdge
    }

    struct Entry {
        var write: QueuedWrite
        var effect = Effect.none
        /// Taken out by a withdraw, so it no longer shows in the rows.
        var withdrawn = false
        var inQueue = true
    }

    struct State {
        var items: [String: Item] = [:]
        var edges: [String: Edge] = [:]
        var edgeOrder: [String: Int] = [:]
        var seedItems: [String: Item] = [:]
        var seedEdges: [String: Edge] = [:]
        var seedEdgeOrder: [String: Int] = [:]
        var givenItemTypes: [String: ItemType] = [:]
        var edgeTypes: [String: EdgeType] = [:]
        var declared: [String: JsonObject] = [:]
        var entries: [Entry] = []
        /// Items made through the copy, which the core holds as pinned.
        var made: Set<String> = []
        /// A view's settings at each version the fake saw, which a stale change is judged against.
        var viewSettings: [String: [Int64: JsonObject]] = [:]
        /// What a view write answered under its idempotency key, so a retry gets the first answer.
        var viewAnswers: [String: ViewAnswer?] = [:]
        var verdict: @Sendable (QueuedWrite) -> Verdict? = { _ in .accepted }
    }

    let state: Mutex<State>
    /// Held for a whole drain, so two never answer the same write.
    let draining = NSLock()

    init(items: [Item], edges: [Edge], itemTypes: [ItemType], edgeTypes: [EdgeType]) {
        var state = State()
        for item in items {
            state.items[item.id] = item
            if item.type == Self.viewType { state.viewSettings[item.id] = [item.version: item.properties] }
        }
        for edge in edges { state.add(edge) }
        (state.seedItems, state.seedEdges, state.seedEdgeOrder) = (state.items, state.edges, state.edgeOrder)
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
                pinned: state.made.filter { state.items[$0] != nil }.sorted {
                    $0.utf8.lexicographicallyPrecedes($1.utf8)
                }, eventCursor: nil,
                hydration: .never, items: UInt64(state.items.count), itemsExpected: nil, itemsListed: nil,
                edges: UInt64(state.edges.count), catalogVersion: nil,
                fileCache: FileCache(
                    setting: .default, budget: nil, held: nil, heldUnreadable: nil, volumeUnreadable: false,
                    backupMarkFailure: nil, attachments: nil))
        }
    }

    // MARK: Reads

    func get(id: String) throws -> Item? {
        state.withLock { state in state.items[id].flatMap { $0.state == .trashed ? nil : $0 } }
    }

    func list(filters: ListFilters, sort: Sort?) throws -> Listing {
        if filters.filter != nil { throw FakeCopyError.unsupported(call: "items.list(filter:)") }
        let order = try Self.order(filters, sort)
        let occurredAfter = try filters.occurredAfter.map(Checks.occurred)
        let occurredBefore = try filters.occurredBefore.map(Checks.occurred)
        let updatedAfter = try filters.updatedAfter.map(Checks.occurred)
        let updatedBefore = try filters.updatedBefore.map(Checks.occurred)
        let listed: [Item] = try state.withLock { state in
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
                if let source = filters.source, !item.source.isBytes(source) { return false }
                if let occurredAfter, item.occurredAt <= occurredAfter { return false }
                if let occurredBefore, item.occurredAt >= occurredBefore { return false }
                if let updatedAfter, item.updatedAt < updatedAfter { return false }
                if let updatedBefore, item.updatedAt >= updatedBefore { return false }
                if let beneath, !beneath.contains(item.id) { return false }
                return filters.tags.allSatisfy(item.tags.contains)
            }
            found.sort { Self.precedes($0, $1, by: order) }
            let offset = Int(filters.offset ?? 0)
            guard offset < found.count else { return [] }
            found.removeFirst(offset)
            if let limit = filters.limit { found = Array(found.prefix(Int(limit))) }
            return found
        }
        return Listing(items: listed, completeness: .complete)
    }

    func getItems(ids: [String], includeBin: Bool) throws -> Listing {
        let found: [Item] = state.withLock { state in
            var seen: Set<String> = []
            return ids.compactMap { id in
                guard seen.insert(id).inserted, let item = state.items[id] else { return nil }
                return includeBin || item.state != .trashed ? item : nil
            }
        }
        return Listing(items: found, completeness: .complete)
    }

    func edge(id: String) throws -> Edge? {
        state.withLock { $0.edges[id] }
    }

    func getEdges(ids: [String]) throws -> [Edge] {
        state.withLock { state in
            var seen: Set<String> = []
            return ids.compactMap { id in seen.insert(id).inserted ? state.edges[id] : nil }
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

    static func root(of name: String) throws -> String? {
        guard name != "*" else { return nil }
        guard Declaring.isTypePattern(name) else {
            throw Refuse.validation("validation_error", "Invalid type identifier: \(name)")
        }
        return name.hasSuffix(".*") ? String(name.dropLast(2)) : name
    }

    /// A type reaches `root` by its name or by a declared parent.
    static func reaches(_ type: String, _ root: String, in types: [String: ItemType]) -> Bool {
        var current: String? = type
        var steps = 0
        while let name = current, steps < 64 {
            if name == root || name.hasPrefix(root + ".") { return true }
            current = types[name]?.parent
            steps += 1
        }
        return false
    }

    /// A list's order as the core answers it: the halves a caller left out are the list's own, which beside
    /// `updatedAfter` is the only order it takes.
    private static func order(_ filters: ListFilters, _ sort: Sort?) throws -> (SortField, SortDirection) {
        let resumed = filters.updatedAfter != nil
        let chosen = (
            sort?.field ?? (resumed ? .updatedAt : .createdAt), sort?.direction ?? (resumed ? .ascending : .descending)
        )
        if case .property(let name) = chosen.0,
            name.isEmpty
                || !name.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F })
        {
            throw Refuse.validation(
                "validation_error", "Invalid sort property field \"\(name)\"; expected ^[a-z0-9_]+$")
        }
        if resumed && (chosen.0 != .updatedAt || chosen.1 != .ascending) && sort != nil {
            throw Refuse.validation(
                "validation_error", "updated_after orders by updated_at, ascending; leave out sort and direction")
        }
        return chosen
    }

    static func precedes(_ lhs: Item, _ rhs: Item, by order: (field: SortField, direction: SortDirection))
        -> Bool
    {
        let ascending = order.direction == .ascending
        if case .property(let name) = order.field {
            switch (propertyKey(lhs, name), propertyKey(rhs, name)) {
            case (nil, nil): return lhs.id < rhs.id
            case (nil, _): return false
            case (_, nil): return true
            case (let left?, let right?):
                if left == right { return lhs.id < rhs.id }
                return ascending ? left < right : right < left
            }
        }
        let (left, right): (String, String) =
            switch order.field {
            case .createdAt: (lhs.createdAt, rhs.createdAt)
            case .updatedAt: (lhs.updatedAt, rhs.updatedAt)
            case .occurredAt: (lhs.occurredAt, rhs.occurredAt)
            case .property: ("", "")
            }
        let ordered = left == right ? lhs.id < rhs.id : left < right
        let reversed = left == right ? lhs.id > rhs.id : left > right
        return ascending ? ordered : reversed
    }

    /// What a property sorts by in the core: numbers and booleans (`false` before `true`) as numbers, text by its
    /// bytes after them, and nothing for a missing, null, object or array value.
    enum PropertyKey: Comparable {
        case number(Double)
        case text([UInt8])

        static func < (lhs: PropertyKey, rhs: PropertyKey) -> Bool {
            switch (lhs, rhs) {
            case (.number(let left), .number(let right)): left < right
            case (.number, .text): true
            case (.text, .number): false
            case (.text(let left), .text(let right)): left.lexicographicallyPrecedes(right)
            }
        }
    }

    static func propertyKey(_ item: Item, _ name: String) -> PropertyKey? {
        guard let value = Properties.value(item.properties, name) else { return nil }
        switch value {
        case .integer(let number): return .number(Double(number))
        case .number(let number): return .number(number)
        case .bool(let flag): return .number(flag ? 1 : 0)
        case .string(let text): return .text(Array(text.utf8))
        case .null, .array, .object: return nil
        }
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
#endif
