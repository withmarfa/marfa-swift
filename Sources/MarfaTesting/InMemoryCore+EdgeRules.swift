#if DEBUG
import Foundation
import MarfaCore

/// The refusals of an edge that the core gives from what the copy holds, in the core's order.
///
/// What the copy does not hold it leaves to the server, as the core does: an edge type or item type outside the
/// catalog, a constraint that only an unreadable part of a type's chain would decide, and an end the copy lacks.
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
        try refuseSelfLoop(draft.sourceId, draft.targetId)
        try Properties.keptAsWritten(draft.properties)
        guard state.items[draft.sourceId] != nil else {
            throw Refuse.invalid(
                "\(draft.sourceId) is not a row this copy holds, and \(draft.edgeType) is not an edge type its slice holds whole, so the copy cannot hold an edge from it"
            )
        }
        try refuseUnwritable(draft, in: state)
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

    /// An end in the bin, an end of a type the edge type does not admit, a source a flat edge type does not take,
    /// then a cycle.
    private static func refuseUnwritable(_ draft: EdgeDraft, in state: State) throws {
        guard let edgeType = state.edgeTypes[draft.edgeType] else { return }
        func end(_ name: String, _ id: String) throws -> String? {
            guard let item = state.items[id] else { return nil }
            if item.state == .trashed {
                throw Refuse.notFound("item_not_found", "Edge \(name) item not found: \(id)")
            }
            return item.type
        }
        let sourceType = try end("source", draft.sourceId)
        let targetType = try end("target", draft.targetId)
        let types = state.resolvedItemTypes()
        if let sourceType, let lineage = lineage(of: sourceType, in: types),
            lineage.admitted(by: edgeType.sourceTypeConstraints) == false
        {
            throw Refuse.validation(
                "edge_constraint_violation", "Edge \"\(draft.edgeType)\" does not allow source type \"\(sourceType)\"")
        }
        if let targetType, let lineage = lineage(of: targetType, in: types),
            lineage.admitted(by: edgeType.targetTypeConstraints) == false
        {
            throw Refuse.validation(
                "edge_constraint_violation", "Edge \"\(draft.edgeType)\" does not allow target type \"\(targetType)\"")
        }
        if edgeType.flat, let sourceType, let lineage = lineage(of: sourceType, in: types),
            lineage.admitted(by: edgeType.targetTypeConstraints) == true
        {
            throw Refuse.validation(
                "edge_constraint_violation",
                "Edge \"\(draft.edgeType)\" does not take a source its target constraints admit; use \"parent-of\" for hierarchy"
            )
        }
        if edgeType.acyclic, state.reaches(from: draft.targetId, to: draft.sourceId, through: draft.edgeType) {
            throw Refuse.validation("edge_cycle", "Edge \"\(draft.edgeType)\" would close a cycle")
        }
    }
}

extension InMemoryCore.State {
    /// Whether `target` reaches `source` through the held edges of one type, those waiting to be sent among them.
    func reaches(from start: String, to goal: String, through edgeType: String) -> Bool {
        var seen: Set<String> = [start]
        var frontier = [start]
        while let at = frontier.popLast() {
            if at == goal { return true }
            for edge in edges.values where edge.edgeType == edgeType && edge.sourceId == at {
                if seen.insert(edge.targetId).inserted { frontier.append(edge.targetId) }
            }
        }
        return false
    }
}
#endif
