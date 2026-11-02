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
        try refuseSelfLoop(draft.edgeType, draft.sourceId, draft.targetId)
        try Properties.keptAsWritten(draft.properties)
        guard state.items[draft.sourceId] != nil else {
            throw Refuse.invalid(
                "\(draft.sourceId) is not a row this copy holds, and \(draft.edgeType) is not an edge type its slice holds whole, so the copy cannot hold an edge from it"
            )
        }
        try refuseUnwritable(
            [
                Proposed(
                    edgeType: draft.edgeType, source: .held(draft.sourceId), targetId: draft.targetId,
                    replacing: draft.id)
            ],
            in: state)
    }

    func checkEdgeMove(id: String, moves: EdgeMove) throws {
        try state.withLock { state in
            guard let held = state.edges[id] else { throw Refuse.edge(id) }
            let (source, target) = Self.endsMoved(held, moves)
            try Self.refuseMove(of: held, source: source, target: target, in: state)
        }
    }

    /// The ends a move names, each left out where the edge already holds it.
    static func endsMoved(_ held: Edge, _ moves: EdgeMove?) -> (source: String?, target: String?) {
        var source = moves.flatMap { $0.end == .source ? $0.to : nil }
        var target = moves.flatMap { $0.end == .target ? $0.to : nil }
        if source == held.sourceId { source = nil }
        if target == held.targetId { target = nil }
        return (source, target)
    }

    /// The refusals `update_edge` gives a move before it queues, in the core's order.
    static func refuseMove(of held: Edge, source: String?, target: String?, in state: State) throws {
        guard source != nil || target != nil else { return }
        if let type = state.edgeTypes[held.edgeType], !holdsOne(type, at: source != nil ? .target : .source) {
            throw Refuse.validation(
                "validation_error",
                "\(held.edgeType) is \(type.cardinality), so the end that stays can hold more than this edge and there is none to replace; create the edge wanted and delete this one"
            )
        }
        try refuseSelfLoop(held.edgeType, source ?? held.sourceId, target ?? held.targetId)
        try refuseUnwritable(
            [
                Proposed(
                    edgeType: held.edgeType, source: .held(source ?? held.sourceId),
                    targetId: target ?? held.targetId, replacing: held.id)
            ],
            in: state)
    }

    static func refuseSelfLoop(_ edgeType: String, _ source: String, _ target: String) throws {
        guard source != target else {
            throw Refuse.validation(
                "edge_cycle", "an edge from \(source) to itself closes a cycle",
                details: Refuse.details(["edge_type": .string(edgeType)]))
        }
    }

    /// Whether an item at `end` holds at most one edge of the type: the core's `EdgeType::one_at`.
    static func holdsOne(_ type: EdgeType, at end: EdgeEnd) -> Bool {
        switch (end, type.cardinality) {
        case (.source, "one-to-one"), (.source, "many-to-one"), (.target, "one-to-one"), (.target, "one-to-many"): true
        default: false
        }
    }

    /// The edge the core's `Proposed` describes: where its source is an item being made, only its type is known.
    struct Proposed {
        enum Source {
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
        var source: Source
        var targetId: String
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
    /// First, for each edge, an end in the bin, an end of a type the edge type does not admit and a source a flat
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
                    && (edge.source.replaced == nil || held.sourceId != edge.source.replaced)
            }
            let sameTriple = { (source: String, target: String) in
                source == edge.source.id && target == edge.targetId
            }
            if standing.contains(where: { sameTriple($0.sourceId, $0.targetId) })
                || earlier.contains(where: { $0.edgeType == edge.edgeType && sameTriple($0.source.id, $0.targetId) })
            {
                throw Refuse.validation(
                    "edge_constraint_violation", "Edge \"\(edge.edgeType)\" already exists between these items",
                    details: Refuse.details([
                        "edge_type": .string(edge.edgeType), "source_id": .string(edge.source.id),
                        "target_id": .string(edge.targetId), "constraint": .string("duplicate"),
                    ]))
            }
            for end in [EdgeEnd.source, .target] where holdsOne(edgeType, at: end) {
                let at = end == .source ? edge.source.id : edge.targetId
                let full =
                    standing.contains { (end == .source ? $0.sourceId : $0.targetId) == at }
                    || earlier.contains {
                        $0.edgeType == edge.edgeType && (end == .source ? $0.source.id : $0.targetId) == at
                    }
                if full { throw refusedCardinality(edgeType, end, at) }
            }
            if edgeType.acyclic,
                state.reaches(from: edge.targetId, to: edge.source.id, through: edge.edgeType, leaving: edge.replacing)
            {
                throw Refuse.validation(
                    "edge_cycle", "Edge \"\(edge.edgeType)\" would close a cycle",
                    details: Refuse.details([
                        "edge_type": .string(edge.edgeType), "source_id": .string(edge.source.id),
                        "target_id": .string(edge.targetId),
                    ]))
            }
        }
    }

    /// An end in the bin, an end of a type the edge type does not admit, then a source a flat edge type does not
    /// take.
    private static func refuseUnfittingEnds(_ edge: Proposed, _ edgeType: EdgeType, in state: State) throws {
        func end(_ name: String, _ id: String) throws -> String? {
            guard let item = state.items[id] else { return nil }
            if item.state == .trashed {
                throw Refuse.notFound("item_not_found", "Edge \(name) item not found: \(id)")
            }
            return item.type
        }
        let sourceType: String?
        switch edge.source {
        case .made(_, let type): sourceType = type
        case .held(let id): sourceType = try end("source", id)
        }
        let targetType = try end("target", edge.targetId)
        let types = state.resolvedItemTypes()
        if let sourceType, let lineage = lineage(of: sourceType, in: types),
            lineage.admitted(by: edgeType.sourceTypeConstraints) == false
        {
            throw refusedEnd(edgeType, .source, sourceType)
        }
        if let targetType, let lineage = lineage(of: targetType, in: types),
            lineage.admitted(by: edgeType.targetTypeConstraints) == false
        {
            throw refusedEnd(edgeType, .target, targetType)
        }
        if edgeType.flat, let sourceType, let lineage = lineage(of: sourceType, in: types),
            lineage.admitted(by: edgeType.targetTypeConstraints) == true
        {
            throw refusedNesting(edge.edgeType, sourceId: edge.source.id, sourceType: sourceType)
        }
    }

    private static func refusedEnd(_ edgeType: EdgeType, _ end: EdgeEnd, _ type: String) -> Error {
        let (name, allowed) =
            end == .source
            ? ("source", edgeType.sourceTypeConstraints) : ("target", edgeType.targetTypeConstraints)
        return Refuse.validation(
            "edge_constraint_violation", "Edge \"\(edgeType.id)\" does not allow \(name) type \"\(type)\"",
            details: Refuse.details([
                "edge_type": .string(edgeType.id), "\(name)_type": .string(type),
                "allowed": .array(allowed.map(JsonValue.string)),
            ]))
    }

    private static func refusedNesting(_ edgeType: String, sourceId: String, sourceType: String) -> Error {
        Refuse.validation(
            "edge_constraint_violation",
            "Edge \"\(edgeType)\" does not take a source its target constraints admit; use \"parent-of\" for hierarchy",
            details: Refuse.details([
                "edge_type": .string(edgeType), "source_id": .string(sourceId), "source_type": .string(sourceType),
                "constraint": .string("nesting"),
            ]))
    }

    private static func refusedCardinality(_ edgeType: EdgeType, _ end: EdgeEnd, _ at: String) -> Error {
        let (name, direction) = end == .source ? ("source", "outbound") : ("target", "inbound")
        return Refuse.validation(
            "edge_constraint_violation",
            "Edge \"\(edgeType.id)\" is \(edgeType.cardinality); \(name) already has an \(direction) edge of this type",
            details: Refuse.details([
                "edge_type": .string(edgeType.id), "\(name)_id": .string(at), "constraint": .string("cardinality"),
            ]))
    }

    /// What the core refuses when `items.update` gives an item a type: each edge it holds, oldest first, whose end
    /// the new type no longer fits.
    static func refuseRetypeBreakingEdges(of id: String, to type: String, in state: State) throws {
        guard let lineage = lineage(of: type, in: state.resolvedItemTypes()) else { return }
        for edge in state.edgesInOrder
        where (edge.sourceId == id || edge.targetId == id) && edge.sourceId != edge.targetId {
            guard let edgeType = state.edgeTypes[edge.edgeType] else { continue }
            let from = edge.sourceId == id
            if from, lineage.admitted(by: edgeType.sourceTypeConstraints) == false {
                throw refusedEnd(edgeType, .source, type)
            }
            if from, edgeType.flat, lineage.admitted(by: edgeType.targetTypeConstraints) == true {
                throw refusedNesting(edge.edgeType, sourceId: id, sourceType: type)
            }
            if !from, lineage.admitted(by: edgeType.targetTypeConstraints) == false {
                throw refusedEnd(edgeType, .target, type)
            }
        }
    }
}

extension InMemoryCore.State {
    /// Whether `target` reaches `source` through the held edges of one type, those waiting to be sent among them.
    func reaches(from start: String, to goal: String, through edgeType: String, leaving replaced: String? = nil) -> Bool
    {
        var seen: Set<String> = [start]
        var frontier = [start]
        while let at = frontier.popLast() {
            if at == goal { return true }
            for edge in edges.values where edge.edgeType == edgeType && edge.sourceId == at && edge.id != replaced {
                if seen.insert(edge.targetId).inserted { frontier.append(edge.targetId) }
            }
        }
        return false
    }
}
#endif
