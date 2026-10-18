import Foundation
import MarfaCore

extension InMemoryCore {
    // MARK: Items

    func createItem(draft: Draft) throws -> QueuedWrite {
        try Properties.cross(draft.properties)
        if draft.sourceId != nil { throw FakeCopyError.unsupported(call: "items.create(sourceId:)") }
        return try state.withLock { state in
            if let id = draft.id, !Minted.isID(id) {
                throw Refuse.validation("invalid_id", "Invalid id: \"\(id)\" is not a UUIDv7 in lowercase")
            }
            let types = state.resolvedItemTypes()
            guard let type = types[draft.type] else {
                throw Refuse.unknownType("\(draft.type) is not a type this copy holds")
            }
            try Self.requireFields(of: type, in: draft.properties)
            let properties = Self.inAnswerOrder(draft.properties, of: type, in: types)
            let id = draft.id ?? Minted.id()
            var body = JsonObject(members: [
                JsonMember(key: "id", value: .string(id)), JsonMember(key: "type", value: .string(draft.type)),
                JsonMember(key: "properties", value: .object(properties)),
                JsonMember(key: "tier", value: .string((draft.tier ?? .library).name)),
            ])
            for (key, value) in [("source", draft.source), ("occurred_at", draft.occurredAt)] {
                if let value { body.members.append(JsonMember(key: key, value: .string(value))) }
            }
            if let version = draft.baseVersion {
                body.members.append(JsonMember(key: "version", value: .integer(version)))
            }
            try Properties.refuseTooDeep(body)
            let at = draft.occurredAt ?? Minted.now()
            state.items[id] = Self.derived(
                Item(
                    id: id, type: draft.type, properties: Properties.served(properties), state: .active,
                    tier: draft.tier ?? .library, version: 0, schemaVersion: 1, source: draft.source ?? "device",
                    sourceId: nil, occurredAt: at, createdAt: at, updatedAt: at,
                    tags: Self.sorted(Set(draft.tags)), title: nil, body: nil, unreadableProperties: nil),
                types: types)
            state.made.insert(id)
            let created = state.append(
                .createItem, item: id, baseVersion: draft.baseVersion, body: body, dependsOn: [])
            for tag in draft.tags {
                state.append(
                    .addTag, item: id, tag: tag, body: Self.tags([tag]), dependsOn: state.pendingCreates(of: id))
            }
            return created
        }
    }

    func updateItem(id: String, edit: Edit) throws -> QueuedWrite {
        try update(id: id, edit: edit, asRead: false)
    }

    func updateItemAsRead(id: String, edit: Edit) throws -> QueuedWrite {
        try update(id: id, edit: edit, asRead: true)
    }

    private func update(id: String, edit: Edit, asRead: Bool) throws -> QueuedWrite {
        try Properties.cross(edit.properties)
        return try state.withLock { state in
            guard var held = state.items[id] else { throw Refuse.item(id) }
            let types = state.resolvedItemTypes()
            let retype = edit.type.flatMap { $0 == held.type ? nil : $0 }
            let tier = edit.tier.flatMap { $0 == held.tier ? nil : $0 }
            if let retype, types[retype] == nil {
                throw Refuse.unknownType("\(retype) is not a type this copy holds, so \(id) cannot move to it")
            }
            let base = edit.baseVersion
            let readEarlier = asRead && base > 0 && base <= held.version
            guard base == held.version || readEarlier else {
                throw Refuse.invalid(
                    "the update to \(id) is based on version \(base) and this copy holds version \(held.version); read it again"
                )
            }
            var body = JsonObject(members: [
                JsonMember(key: "properties", value: .object(edit.properties)),
                JsonMember(key: "version", value: .integer(base)),
            ])
            if edit.replaceProperties { body.members.append(.init(key: "properties_mode", value: .string("replace"))) }
            if let key = edit.sourceId { body.members.append(.init(key: "source_id", value: .string(key))) }
            if let retype {
                body.members.append(.init(key: "type", value: .string(retype)))
                body.members.append(.init(key: "retype", value: .bool(true)))
            }
            if let tier { body.members.append(.init(key: "tier", value: .string(tier.name))) }
            try Properties.refuseTooDeep(body)
            held.properties = Properties.merged(
                held.properties, with: edit.properties, replacing: edit.replaceProperties)
            if let key = edit.sourceId { held.sourceId = key }
            if let retype { held.type = retype }
            if let tier { held.tier = tier }
            if let type = types[held.type], base == held.version {
                try Self.requireFields(of: type, in: held.properties)
            }
            state.items[id] = Self.derived(held, types: types)
            return state.append(
                .updateItem, item: id, baseVersion: base, body: body, dependsOn: state.pendingCreates(of: id))
        }
    }

    func deleteItem(id: String) throws -> QueuedWrite {
        try state.withLock { state in
            guard var held = state.items[id] else { throw Refuse.item(id) }
            let body = JsonObject(members: [JsonMember(key: "version", value: .integer(held.version))])
            held.state = .trashed
            state.items[id] = held
            return state.append(
                .deleteItem, item: id, baseVersion: held.version, body: body, dependsOn: state.pendingCreates(of: id))
        }
    }

    func restoreItem(id: String) throws -> QueuedWrite {
        try state.withLock { state in
            guard var held = state.items[id] else { throw Refuse.item(id) }
            held.state = .active
            state.items[id] = held
            return state.append(.restoreItem, item: id, body: JsonObject(), dependsOn: state.pendingCreates(of: id))
        }
    }

    func transitionItem(id: String, state target: ItemState) throws -> QueuedWrite {
        try state.withLock { state in
            guard var held = state.items[id] else { throw Refuse.item(id) }
            held.state = target
            state.items[id] = held
            let body = JsonObject(members: [JsonMember(key: "state", value: .string(target.name))])
            return state.append(.transitionItem, item: id, body: body, dependsOn: state.pendingCreates(of: id))
        }
    }

    // MARK: Tags and extensions

    func addTag(id: String, tag: String) throws -> QueuedWrite {
        try tagged(id, .addTag, tag: tag, body: Self.tags([tag])) { Self.sorted(Set($0).union([tag])) }
    }

    func removeTag(id: String, tag: String) throws -> QueuedWrite {
        try tagged(id, .removeTag, tag: tag, body: JsonObject()) { $0.filter { $0 != tag } }
    }

    func replaceMetadata(id: String, tags: [String]) throws -> QueuedWrite {
        try tagged(id, .replaceMetadata, tag: nil, body: Self.tags(tags)) { _ in Self.sorted(Set(tags)) }
    }

    func mergeMetadata(id: String, tags: [String]) throws -> QueuedWrite {
        try tagged(id, .mergeMetadata, tag: nil, body: Self.tags(tags)) { Self.sorted(Set($0).union(tags)) }
    }

    private func tagged(
        _ id: String, _ kind: WriteKind, tag: String?, body: JsonObject, _ change: ([String]) -> [String]
    ) throws -> QueuedWrite {
        try state.withLock { state in
            guard var held = state.items[id] else { throw Refuse.item(id) }
            held.tags = change(held.tags)
            state.items[id] = held
            return state.append(kind, item: id, tag: tag, body: body, dependsOn: state.pendingCreates(of: id))
        }
    }

    func writeExtension(id: String, namespace: String, body: JsonObject) throws -> QueuedWrite {
        try Properties.cross(body)
        return try state.withLock { state in
            guard state.items[id] != nil else { throw Refuse.item(id) }
            try Properties.refuseTooDeep(body)
            return state.append(
                .writeExtension, item: id, namespace: namespace, body: body, dependsOn: state.pendingCreates(of: id))
        }
    }

    func deleteExtension(id: String, namespace: String) throws -> QueuedWrite {
        try state.withLock { state in
            guard state.items[id] != nil else { throw Refuse.item(id) }
            return state.append(
                .deleteExtension, item: id, namespace: namespace, body: JsonObject(),
                dependsOn: state.pendingCreates(of: id))
        }
    }

    // MARK: Edges

    func createEdge(draft: EdgeDraft) throws -> QueuedWrite {
        try Properties.cross(draft.properties)
        return try state.withLock { state in
            if let id = draft.id, !Minted.isID(id) {
                throw Refuse.validation("invalid_id", "Invalid id: \"\(id)\" is not a UUIDv7 in lowercase")
            }
            try Self.refuseSelfLoop(draft.sourceId, draft.targetId)
            guard state.items[draft.sourceId] != nil else {
                throw Refuse.invalid(
                    "\(draft.sourceId) is not a row this copy holds, and \(draft.edgeType) is not an edge type its slice holds whole, so the copy cannot hold an edge from it"
                )
            }
            let id = draft.id ?? Minted.id()
            let body = JsonObject(members: [
                .init(key: "id", value: .string(id)), .init(key: "source_id", value: .string(draft.sourceId)),
                .init(key: "target_id", value: .string(draft.targetId)),
                .init(key: "edge_type", value: .string(draft.edgeType)),
                .init(key: "properties", value: .object(draft.properties)),
            ])
            try Properties.refuseTooDeep(body)
            let at = Minted.now()
            state.add(
                Edge(
                    id: id, sourceId: draft.sourceId, targetId: draft.targetId, edgeType: draft.edgeType,
                    properties: Properties.served(draft.properties), version: 0, createdAt: at, updatedAt: at,
                    unreadableProperties: nil))
            return state.append(
                .createEdge, item: draft.sourceId, target: draft.targetId, edge: id, body: body,
                dependsOn: state.pendingCreates(of: draft.sourceId, draft.targetId))
        }
    }

    func updateEdge(id: String, edit: EdgeEdit) throws -> QueuedWrite? {
        try Properties.cross(edit.properties)
        return try state.withLock { state in
            guard var held = state.edges[id] else { throw Refuse.edge(id) }
            let base = edit.baseVersion
            guard base == held.version else {
                throw Refuse.invalid(
                    "the update to edge \(id) is based on version \(base) and this copy holds version \(held.version); read it again"
                )
            }
            var source = edit.moves.flatMap { $0.end == .source ? $0.to : nil }
            var target = edit.moves.flatMap { $0.end == .target ? $0.to : nil }
            if source == held.sourceId { source = nil }
            if target == held.targetId { target = nil }
            if source != nil || target != nil {
                let type = state.edgeTypes[held.edgeType]
                if let type, !Self.holdsAtMostOne(type, at: source != nil ? .target : .source) {
                    throw Refuse.validation(
                        "validation_error",
                        "\(held.edgeType) is \(type.cardinality), so the end that stays can hold more than this edge and there is none to replace; create the edge wanted and delete this one"
                    )
                }
                try Self.refuseSelfLoop(source ?? held.sourceId, target ?? held.targetId)
            }
            guard !edit.properties.members.isEmpty || source != nil || target != nil else { return nil }
            var body = JsonObject(members: [
                .init(key: "properties", value: .object(edit.properties)), .init(key: "version", value: .integer(base)),
            ])
            if let source { body.members.append(.init(key: "source_id", value: .string(source))) }
            if let target { body.members.append(.init(key: "target_id", value: .string(target))) }
            try Properties.refuseTooDeep(body)
            var dependsOn = state.pendingCreate(ofEdge: id)
            for waited in state.pendingCreates(of: [source, target].compactMap { $0 }) where !dependsOn.contains(waited)
            {
                dependsOn.append(waited)
            }
            let (from, to) = (held.sourceId, held.targetId)
            var members = held.properties.members
            for member in edit.properties.members {
                if let at = members.firstIndex(where: { $0.key.utf8.elementsEqual(member.key.utf8) }) {
                    members[at] = member
                } else {
                    members.append(member)
                }
            }
            held.properties = Properties.served(JsonObject(members: members))
            if let source { held.sourceId = source }
            if let target { held.targetId = target }
            state.edges[id] = held
            return state.append(
                .updateEdge, item: from, target: to, edge: id, baseVersion: base, body: body, dependsOn: dependsOn)
        }
    }

    func deleteEdge(id: String) throws -> QueuedWrite {
        try state.withLock { state in
            guard let held = state.edges[id] else { throw Refuse.edge(id) }
            let body = JsonObject(members: [.init(key: "edge_type", value: .string(held.edgeType))])
            let dependsOn = state.pendingCreate(ofEdge: id)
            state.edges[id] = nil
            state.edgeOrder[id] = nil
            return state.append(
                .deleteEdge, item: held.sourceId, target: held.targetId, edge: id, body: body, dependsOn: dependsOn)
        }
    }

    private static func refuseSelfLoop(_ source: String, _ target: String) throws {
        guard source != target else {
            throw Refuse.validation("edge_cycle", "an edge from \(source) to itself closes a cycle")
        }
    }

    /// Whether an item at `end` holds at most one edge of the type.
    private static func holdsAtMostOne(_ type: EdgeType, at end: EdgeEnd) -> Bool {
        switch (end, type.cardinality) {
        case (.source, "one-to-one"), (.source, "many-to-one"), (.target, "one-to-one"), (.target, "one-to-many"): true
        default: false
        }
    }

    // MARK: Shared

    private static func requireFields(of type: ItemType, in properties: JsonObject) throws {
        for field in type.fields where field.required && Properties.value(properties, field.name) == nil {
            throw Refuse.validation("invalid_properties", "\(field.name): Required field is missing")
        }
    }

    /// A create's properties as the server holds them: a null on a field the
    /// type declares and does not require is dropped, and the fields the type
    /// declares come first, its ancestors' before its own, then the rest as
    /// given.
    private static func inAnswerOrder(
        _ properties: JsonObject, of type: ItemType, in types: [String: ItemType]
    ) -> JsonObject {
        let kept = properties.members.filter { member in
            guard member.value == .null, let field = type.fields.first(where: { $0.name == member.key }) else {
                return true
            }
            return field.required
        }
        var chain: [String] = []
        var current: ItemType? = type
        while let next = current, chain.count < 64, !chain.contains(next.id) {
            chain.insert(next.id, at: 0)
            current = next.parent.flatMap { types[$0] }
        }
        var ordered: [JsonMember] = []
        for id in chain {
            for field in type.fields where field.declaredBy == id {
                if let member = kept.first(where: { $0.key == field.name }),
                    !ordered.contains(where: { $0.key == field.name })
                {
                    ordered.append(member)
                }
            }
        }
        return JsonObject(members: ordered + kept.filter { member in !ordered.contains { $0.key == member.key } })
    }

    private static func tags(_ tags: [String]) -> JsonObject {
        JsonObject(members: [JsonMember(key: "tags", value: .array(tags.map { .string($0) }))])
    }

    private static func sorted(_ tags: Set<String>) -> [String] {
        tags.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// The item with the title and body its type's hints name.
    private static func derived(_ item: Item, types: [String: ItemType]) -> Item {
        let type = types[item.type]
        var item = item
        item.title = Properties.string(item.properties, type?.titleField ?? "title")
        item.body = Properties.string(item.properties, type?.bodyField ?? "body")
        return item
    }
}

extension InMemoryCore.State {
    /// Queues a write, behind the creates it cannot go without and the write
    /// ahead of it to the same row.
    @discardableResult
    mutating func append(
        _ kind: WriteKind, item: String, target: String? = nil, edge: String? = nil, namespace: String? = nil,
        tag: String? = nil, baseVersion: Int64? = nil, body: JsonObject, dependsOn: [String]
    ) -> QueuedWrite {
        let ahead = entries.last {
            $0.inQueue && $0.write.verdict == nil
                && (edge != nil ? $0.write.edgeId == edge : $0.write.edgeId == nil && $0.write.itemId == item)
        }
        let write = QueuedWrite(
            id: Minted.id(), kind: kind, itemId: item, targetId: target, edgeId: edge, namespace: namespace, tag: tag,
            blob: nil, baseVersion: baseVersion, idempotencyKey: Minted.id(), dependsOn: dependsOn,
            follows: ahead?.write.id, verdict: nil, waiting: false, body: body, answer: nil, refusals: 0,
            queuedAt: Minted.now(), answeredAt: nil)
        entries.append(InMemoryCore.Entry(write: write))
        return write
    }

    /// The creates of these items that no answer has settled.
    func pendingCreates(of ids: String...) -> [String] {
        pendingCreates(of: ids)
    }

    func pendingCreates(of ids: [String]) -> [String] {
        var found: [String] = []
        for id in ids {
            for entry in entries
            where entry.inQueue && entry.write.kind == .createItem && entry.write.itemId == id
                && entry.write.verdict == nil && !found.contains(entry.write.id)
            {
                found.append(entry.write.id)
            }
        }
        return found
    }

    func pendingCreate(ofEdge id: String) -> [String] {
        entries.filter {
            $0.inQueue && $0.write.kind == .createEdge && $0.write.edgeId == id && $0.write.verdict == nil
        }.map(\.write.id)
    }
}

extension Tier {
    var name: String {
        switch self {
        case .library: "library"
        case .feed: "feed"
        }
    }
}

extension ItemState {
    var name: String {
        switch self {
        case .active: "active"
        case .archived: "archived"
        case .trashed: "trashed"
        case .revoked: "revoked"
        }
    }
}
