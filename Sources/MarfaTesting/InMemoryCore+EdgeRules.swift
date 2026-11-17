#if DEBUG
import Foundation
import MarfaCore

/// The refusals of an edge that the core gives from what the copy holds, in the core's order, each with the
/// `details` the core gives it.
///
/// What the copy does not hold it leaves to the server, as the core does: an edge type or item type outside the
/// catalog, a constraint that only an unreadable part of a type's chain would decide, and an end the copy lacks.
/// The edges counted are those the fake shows, its waiting writes included; a write a drain refuses puts its edge
/// back at once, as the core shows it once the read of the refused row lands.
extension InMemoryCore {
    func checkEdge(draft: EdgeDraft) throws {
        try Properties.cross(draft.properties)
        try state.withLock { state in
            try Self.refuseUnqueueable(draft, in: state)
        }
    }

    /// The checks `create_edge` makes before it queues, in the core's order.
    static func refuseUnqueueable(_ draft: EdgeDraft, in state: State) throws {
        if let id = draft.id, !Minted.isID(id) {
            throw Refuse.validation("invalid_id", "Invalid id: \"\(id)\" is not a UUIDv7 in lowercase")
        }
        try refuseSelfLoop(draft.edgeType, draft.fromId, draft.toId)
        try Properties.keptAsWritten(draft.properties)
        guard state.items[draft.fromId] != nil else {
            throw Refuse.invalid(
                "\(draft.fromId) is not a row this copy holds, and \(draft.edgeType) is not an edge type its slice holds whole, so the copy cannot hold an edge from it"
            )
        }
        try refuseUnwritable(
            [
                Proposed(
                    edgeType: draft.edgeType, from: .held(draft.fromId), toId: draft.toId,
                    replacing: draft.id)
            ],
            in: state)
    }

    func checkEdgeMove(id: String, moves: EdgeMove) throws {
        try state.withLock { state in
            guard let held = state.edges[id] else { throw Refuse.edge(id) }
            let (from, to) = Self.endsMoved(held, moves)
            try Self.refuseMove(of: held, from: from, to: to, in: state)
        }
    }

    /// The ends a move names, each left out where the edge already holds it.
    static func endsMoved(_ held: Edge, _ moves: EdgeMove?) -> (from: String?, to: String?) {
        var from = moves.flatMap { $0.end == .from ? $0.to : nil }
        var to = moves.flatMap { $0.end == .to ? $0.to : nil }
        if from == held.fromId { from = nil }
        if to == held.toId { to = nil }
        return (from, to)
    }

    /// The refusals `update_edge` gives a move before it queues, in the core's order.
    static func refuseMove(of held: Edge, from: String?, to: String?, in state: State) throws {
        guard from != nil || to != nil else { return }
        if let type = state.edgeTypes[held.edgeType], !holdsOne(type, at: from != nil ? .to : .from) {
            throw Refuse.validation(
                "validation_error",
                "\(held.edgeType) is \(type.cardinality), so the end that stays can hold more than this edge and there is none to replace; create the edge wanted and delete this one"
            )
        }
        try refuseSelfLoop(held.edgeType, from ?? held.fromId, to ?? held.toId)
        try refuseUnwritable(
            [
                Proposed(
                    edgeType: held.edgeType, from: .held(from ?? held.fromId),
                    toId: to ?? held.toId, replacing: held.id)
            ],
            in: state)
    }

    static func refuseSelfLoop(_ edgeType: String, _ from: String, _ to: String) throws {
        guard from != to else {
            throw Refuse.validation(
                "edge_cycle", "an edge from \(from) to itself closes a cycle",
                details: Refuse.details(["edge_type": .string(edgeType)]))
        }
    }

    /// Whether an item at `end` holds at most one edge of the type: the core's `EdgeType::one_at`.
    static func holdsOne(_ type: EdgeType, at end: EdgeEnd) -> Bool {
        switch (end, type.cardinality) {
        case (.from, "one-to-one"), (.from, "many-to-one"), (.to, "one-to-one"), (.to, "one-to-many"): true
        default: false
        }
    }

    /// The edge the core's `Proposed` describes: where its from end is an item being made, only its type is known.
    struct Proposed {
        enum From {
            case held(String)
            case made(id: String, type: String)

            var id: String {
                switch self {
                case .held(let id), .made(let id, _): id
                }
            }

            /// The row whose outbound edges of the type a create replaces, which the checks leave out.
            var replaced: String? {
                switch self {
                case .held: nil
                case .made(let id, _): id
                }
            }
        }

        var edgeType: String
        var from: From
        var toId: String
        /// The held edge the write is, which its own checks leave out.
        ///
        /// It is the edge an update moves an end of, or the one a create names by id.
        var replacing: String?
    }

    private struct Lineage {
        var ancestors: [String] = []
        var roles: [String] = []
        /// False where a parent the copy does not hold, or a chain that loops, leaves what is above unknown.
        var whole = true

        func admitted(by constraints: [String]) -> Bool? {
            let admitted =
                constraints.isEmpty
                || constraints.contains { allowed in
                    if allowed == "*" { return true }
                    if allowed.hasPrefix("role:") { return roles.contains(String(allowed.dropFirst(5))) }
                    return ancestors.contains(allowed)
                }
            return admitted || whole ? admitted : nil
        }
    }

    private static func lineage(of type: String, in types: [String: ItemType]) -> Lineage? {
        guard types[type] != nil else { return nil }
        var lineage = Lineage()
        var current: String? = type
        while let at = current {
            if lineage.ancestors.count >= 64 || lineage.ancestors.contains(at) {
                lineage.whole = false
                break
            }
            lineage.ancestors.append(at)
            guard let row = types[at] else {
                lineage.whole = false
                break
            }
            for role in row.roles where !lineage.roles.contains(role) { lineage.roles.append(role) }
            current = row.parent
        }
        return lineage
    }

    /// The refusals of the edges one write makes, in the core's order.
    ///
    /// First, for each edge, an end in the bin, an end of a type the edge type does not admit and a from end a flat
    /// edge type does not take; then, edge by edge, a triple the copy shows, an end that already holds the one edge
    /// of the type it may, and a cycle. Each edge is counted with those before it in the same write.
    static func refuseUnwritable(_ edges: [Proposed], in state: State) throws {
        var judged: [(edge: Proposed, type: EdgeType)] = []
        for edge in edges {
            guard let edgeType = state.edgeTypes[edge.edgeType] else { continue }
            try refuseUnfittingEnds(edge, edgeType, in: state)
            judged.append((edge, edgeType))
        }
        for (index, (edge, edgeType)) in judged.enumerated() {
            let earlier = judged[..<index].map(\.edge)
            let standing = state.edges.values.filter { held in
                held.edgeType == edge.edgeType && held.id != edge.replacing
                    && (edge.from.replaced == nil || held.fromId != edge.from.replaced)
            }
            let sameTriple = { (from: String, to: String) in
                from == edge.from.id && to == edge.toId
            }
            if standing.contains(where: { sameTriple($0.fromId, $0.toId) })
                || earlier.contains(where: { $0.edgeType == edge.edgeType && sameTriple($0.from.id, $0.toId) })
            {
                throw Refuse.validation(
                    "edge_constraint_violation", "Edge \"\(edge.edgeType)\" already exists between these items",
                    details: Refuse.details([
                        "edge_type": .string(edge.edgeType), "from_id": .string(edge.from.id),
                        "to_id": .string(edge.toId), "constraint": .string("duplicate"),
                    ]))
            }
            for end in [EdgeEnd.from, .to] where holdsOne(edgeType, at: end) {
                let at = end == .from ? edge.from.id : edge.toId
                let full =
                    standing.contains { (end == .from ? $0.fromId : $0.toId) == at }
                    || earlier.contains {
                        $0.edgeType == edge.edgeType && (end == .from ? $0.from.id : $0.toId) == at
                    }
                if full { throw refusedCardinality(edgeType, end, at) }
            }
            if edgeType.acyclic,
                state.reaches(from: edge.toId, to: edge.from.id, through: edge.edgeType, leaving: edge.replacing)
            {
                throw Refuse.validation(
                    "edge_cycle", "Edge \"\(edge.edgeType)\" would close a cycle",
                    details: Refuse.details([
                        "edge_type": .string(edge.edgeType), "from_id": .string(edge.from.id),
                        "to_id": .string(edge.toId),
                    ]))
            }
        }
    }

    /// An end in the bin, an end of a type the edge type does not admit, then a from end a flat edge type does not
    /// take.
    private static func refuseUnfittingEnds(_ edge: Proposed, _ edgeType: EdgeType, in state: State) throws {
        func end(_ name: String, _ id: String) throws -> String? {
            guard let item = state.items[id] else { return nil }
            if item.state == .trashed {
                throw Refuse.notFound("item_not_found", "Edge \(name) item not found: \(id)")
            }
            return item.type
        }
        let fromType: String?
        switch edge.from {
        case .made(_, let type): fromType = type
        case .held(let id): fromType = try end("from", id)
        }
        let toType = try end("to", edge.toId)
        let types = state.resolvedItemTypes()
        if let fromType, let lineage = lineage(of: fromType, in: types),
            lineage.admitted(by: edgeType.fromTypeConstraints) == false
        {
            throw refusedEnd(edgeType, .from, fromType)
        }
        if let toType, let lineage = lineage(of: toType, in: types),
            lineage.admitted(by: edgeType.toTypeConstraints) == false
        {
            throw refusedEnd(edgeType, .to, toType)
        }
        if edgeType.flat, let fromType, let lineage = lineage(of: fromType, in: types),
            lineage.admitted(by: edgeType.toTypeConstraints) == true
        {
            throw refusedNesting(edge.edgeType, fromId: edge.from.id, fromType: fromType)
        }
    }

    private static func refusedEnd(_ edgeType: EdgeType, _ end: EdgeEnd, _ type: String) -> Error {
        let (name, allowed) =
            end == .from
            ? ("from", edgeType.fromTypeConstraints) : ("to", edgeType.toTypeConstraints)
        return Refuse.validation(
            "edge_constraint_violation", "Edge \"\(edgeType.id)\" does not allow type \"\(type)\" at its \(name) end",
            details: Refuse.details([
                "edge_type": .string(edgeType.id), "\(name)_type": .string(type),
                "allowed": .array(allowed.map(JsonValue.string)),
            ]))
    }

    private static func refusedNesting(_ edgeType: String, fromId: String, fromType: String) -> Error {
        Refuse.validation(
            "edge_constraint_violation",
            "Edge \"\(edgeType)\" does not take a from item its to constraints admit; use \"parent-of\" for hierarchy",
            details: Refuse.details([
                "edge_type": .string(edgeType), "from_id": .string(fromId), "from_type": .string(fromType),
                "constraint": .string("nesting"),
            ]))
    }

    private static func refusedCardinality(_ edgeType: EdgeType, _ end: EdgeEnd, _ at: String) -> Error {
        let (name, direction) = end == .from ? ("from", "outbound") : ("to", "inbound")
        let limit =
            edgeType.cardinality == "one-to-one"
            ? "is one-to-one; the \(name) item already has one"
            : "is \(edgeType.cardinality) on the \(name) side; the \(name) item already has an"
        return Refuse.validation(
            "edge_constraint_violation",
            "Edge \"\(edgeType.id)\" \(limit) \(direction) edge of this type",
            details: Refuse.details([
                "edge_type": .string(edgeType.id), "\(name)_id": .string(at), "constraint": .string("cardinality"),
            ]))
    }

    /// What the core refuses when `items.update` gives an item a type: each edge it holds, oldest first, whose end
    /// the new type no longer fits.
    static func refuseRetypeBreakingEdges(of id: String, to type: String, in state: State) throws {
        guard let lineage = lineage(of: type, in: state.resolvedItemTypes()) else { return }
        for edge in state.edgesInOrder
        where (edge.fromId == id || edge.toId == id) && edge.fromId != edge.toId {
            guard let edgeType = state.edgeTypes[edge.edgeType] else { continue }
            let from = edge.fromId == id
            if from, lineage.admitted(by: edgeType.fromTypeConstraints) == false {
                throw refusedEnd(edgeType, .from, type)
            }
            if from, edgeType.flat, lineage.admitted(by: edgeType.toTypeConstraints) == true {
                throw refusedNesting(edge.edgeType, fromId: id, fromType: type)
            }
            if !from, lineage.admitted(by: edgeType.toTypeConstraints) == false {
                throw refusedEnd(edgeType, .to, type)
            }
        }
    }
}

extension InMemoryCore.State {
    /// Whether `start` reaches `goal` through the held edges of one type, those waiting to be sent among them.
    func reaches(from start: String, to goal: String, through edgeType: String, leaving replaced: String? = nil) -> Bool
    {
        var seen: Set<String> = [start]
        var frontier = [start]
        while let at = frontier.popLast() {
            if at == goal { return true }
            for edge in edges.values where edge.edgeType == edgeType && edge.fromId == at && edge.id != replaced {
                if seen.insert(edge.toId).inserted { frontier.append(edge.toId) }
            }
        }
        return false
    }
}
#endif
