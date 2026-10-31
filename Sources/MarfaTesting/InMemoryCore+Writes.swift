#if DEBUG
import CryptoKit
import Foundation
import MarfaCore

extension InMemoryCore {
    // MARK: Items

    func createItem(draft: Draft) throws -> QueuedWrite {
        try Properties.cross(draft.properties)
        try Checks.links(draft.properties, call: "items.create")
        if draft.sourceId != nil { throw FakeCopyError.unsupported(call: "items.create(sourceId:)") }
        return try state.withLock { state in
            try Checks.tags(draft.tags)
            try Properties.keptAsWritten(draft.properties)
            if let id = draft.id, !Minted.isID(id) {
                throw Refuse.validation("invalid_id", "Invalid id: \"\(id)\" is not a UUIDv7 in lowercase")
            }
            try Checks.writable(draft.type)
            let types = state.resolvedItemTypes()
            guard let type = types[draft.type] else {
                throw Refuse.unknownType("\(draft.type) is not a type this copy holds")
            }
            let edges = try Checks.createFields(draft)
            let kept = Self.droppingOptionalNulls(draft.properties, of: type)
            try Checks.properties(kept, of: type, call: "items.create")
            try Self.requireFields(of: type, in: kept)
            try Checks.statusWord(kept, of: type, call: "items.create")
            let properties = Self.inAnswerOrder(kept, of: type, in: types)
            let id = draft.id ?? Minted.id()
            for named in edges {
                for target in named.targets {
                    try Self.refuseUnwritable(
                        Proposed(
                            edgeType: named.type, source: .made(id: id, type: draft.type), targetId: target,
                            replacing: nil),
                        in: state)
                }
            }
            var body = JsonObject(members: [
                JsonMember(key: "id", value: .string(id)), JsonMember(key: "type", value: .string(draft.type)),
                JsonMember(key: "properties", value: .object(properties)),
                JsonMember(key: "tier", value: .string((draft.tier ?? .library).name)),
            ])
            if let created = draft.state { body.members.append(.init(key: "state", value: .string(created.name))) }
            for (key, value) in [
                ("capture_latitude", draft.captureLatitude), ("capture_longitude", draft.captureLongitude),
            ] {
                if let value { body.members.append(.init(key: key, value: .number(value))) }
            }
            if !edges.isEmpty {
                let named = edges.map { JsonMember(key: $0.type, value: .array($0.targets.map { .string($0) })) }
                body.members.append(.init(key: "edges", value: .object(JsonObject(members: named))))
            }
            for (key, value) in [("source", draft.source), ("occurred_at", draft.occurredAt)] {
                if let value { body.members.append(JsonMember(key: key, value: .string(value))) }
            }
            if let version = draft.baseVersion {
                body.members.append(JsonMember(key: "version", value: .integer(version)))
            }
            let at = try draft.occurredAt.map(Checks.occurred) ?? Minted.now()
            try Properties.refuseTooDeep(body)
            let made = Item(
                id: id, type: draft.type, properties: Properties.served(properties), state: draft.state ?? .active,
                tier: draft.tier ?? .library, version: 0, schemaVersion: 1, source: draft.source ?? "device",
                sourceId: nil, occurredAt: at, createdAt: at, updatedAt: at,
                tags: Self.applying(.replace(draft.tags), to: []), captureLatitude: draft.captureLatitude,
                captureLongitude: draft.captureLongitude, trashedAt: draft.state == .trashed ? Minted.now() : nil,
                title: nil, body: nil, unreadableProperties: nil)
            state.items[id] = Self.derived(made, types: types)
            state.made.insert(id)
            let shown = edges.flatMap { named in
                named.targets.map { target in
                    Edge(
                        id: Self.projectedEdgeID(id, named.type, target), sourceId: id, targetId: target,
                        edgeType: named.type, properties: JsonObject(members: []), version: 0, createdAt: at,
                        updatedAt: at, unreadableProperties: nil)
                }
            }
            for edge in shown { state.add(edge) }
            let created = state.append(
                .createItem, item: id, baseVersion: draft.baseVersion, body: body,
                dependsOn: state.pendingCreates(of: edges.flatMap(\.targets)),
                effect: .made(Self.derived(Self.withoutTags(made), types: types), edges: shown))
            for tag in draft.tags {
                state.append(
                    .addTag, item: id, tag: tag, body: Self.tags([tag]), dependsOn: state.pendingCreates(of: id),
                    effect: .tags(.add(tag)))
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
        try Checks.links(edit.properties, call: "items.update")
        try Properties.keptAsWritten(edit.properties)
        if edit.clearOccurredAt && edit.occurredAt != nil {
            throw Refuse.invalid("an edit sets the item's time or clears it, not both")
        }
        let named = try edit.occurredAt.map(Checks.occurred)
        return try state.withLock { state in
            guard var held = state.items[id], held.state != .trashed else { throw Refuse.item(id) }
            try Checks.writable(held.type)
            if let type = edit.type { try Checks.writable(type) }
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
            if let type = edit.type { try Self.refuseRetypeBreakingEdges(of: id, to: type, in: state) }
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
            // The server holds no empty time: an item with none of its own takes its creation time. While its
            // create is unsent, none is sent at all, and the server places the create at its own creation time.
            let waiting = state.entries.indices.filter {
                let entry = state.entries[$0]
                return entry.inQueue && entry.write.verdict == nil && entry.write.kind == .createItem
                    && entry.write.itemId == id
            }
            var unsentCreate: Int?
            if edit.clearOccurredAt {
                if waiting.count == 1 { unsentCreate = waiting[0] }
                if unsentCreate == nil {
                    body.members.append(.init(key: "occurred_at", value: .string(held.createdAt)))
                }
            } else if let occurredAt = edit.occurredAt {
                body.members.append(.init(key: "occurred_at", value: .string(occurredAt)))
            }
            try Properties.refuseTooDeep(body)
            let target = types[retype ?? held.type]
            if let target {
                try Checks.properties(edit.properties, of: target, call: "items.update")
            }
            // An edit based on an earlier version did not read the copy's row,
            // so it cannot know which properties it clears: it merges.
            let replacing = edit.replaceProperties && base == held.version
            let before = held.properties
            held.properties = Properties.merged(held.properties, with: edit.properties, replacing: replacing)
            // A status word is judged where the edit changes it, and a move changes every property.
            let written = retype == nil ? Self.changed(edit.properties, from: before) : held.properties
            if let target { try Checks.statusWord(written, of: target, call: "items.update") }
            if let type = types[retype ?? held.type], base == held.version {
                try Self.requireFields(of: type, in: held.properties)
            }
            if let key = edit.sourceId { held.sourceId = key }
            if let retype { held.type = retype }
            if let tier { held.tier = tier }
            var shownTime = named
            if edit.clearOccurredAt { shownTime = unsentCreate == nil ? held.createdAt : nil }
            if let shownTime { held.occurredAt = shownTime }
            if let unsentCreate {
                let queued = state.entries[unsentCreate].write.queuedAt
                held.occurredAt = queued
                held.createdAt = queued
                state.dropUnsentTime(of: id)
            }
            state.items[id] = Self.derived(held, types: types)
            return state.append(
                .updateItem, item: id, baseVersion: base, body: body, dependsOn: state.pendingCreates(of: id),
                effect: .edit(
                    properties: edit.properties, replacing: replacing, type: retype, tier: tier,
                    sourceId: edit.sourceId,
                    occurredAt: shownTime))
        }
    }

    /// The id the core gives the edge it shows from a create that waits, which the same create always shows again.
    static func projectedEdgeID(_ source: String, _ edgeType: String, _ target: String) -> String {
        var hash = SHA256()
        for part in [source, edgeType, target] {
            var length = UInt64(part.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(bufferPointer: $0) }
            hash.update(data: Data(part.utf8))
        }
        var bytes = Array(hash.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }
        return [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]].map { $0.joined() }.joined(
            separator: "-")
    }

    func deleteItem(id: String) throws -> QueuedWrite {
        try state.withLock { state in
            guard var held = state.items[id] else { throw Refuse.item(id) }
            let body = JsonObject(members: [JsonMember(key: "version", value: .integer(held.version))])
            let at = Minted.now()
            held.move(to: .trashed, at: at)
            state.items[id] = held
            return state.append(
                .deleteItem, item: id, baseVersion: held.version, body: body, dependsOn: state.pendingCreates(of: id),
                effect: .state(.trashed, at: at))
        }
    }

    /// An item the copy does not hold is restored by id: queued, and shown
    /// nowhere until the server answers.
    func restoreItem(id: String) throws -> QueuedWrite {
        state.withLock { state in
            guard var held = state.items[id] else {
                return state.append(.restoreItem, item: id, body: JsonObject(), dependsOn: [])
            }
            let at = Minted.now()
            held.move(to: .active, at: at)
            state.items[id] = held
            return state.append(
                .restoreItem, item: id, body: JsonObject(), dependsOn: state.pendingCreates(of: id),
                effect: .state(.active, at: at))
        }
    }

    func transitionItem(id: String, state target: ItemState) throws -> QueuedWrite {
        try state.withLock { state in
            guard var held = state.items[id] else { throw Refuse.item(id) }
            if target == .revoked {
                if held.type.hasPrefix("system.") {
                    throw FakeCopyError.unsupported(call: "items.transition(to: .revoked) on a system type")
                }
                throw Refuse.invalid(
                    "a device cannot move \(id) to the revoked state; it is reachable only on a reserved type and on the server's authority"
                )
            }
            let at = Minted.now()
            held.move(to: target, at: at)
            state.items[id] = held
            let body = JsonObject(members: [JsonMember(key: "state", value: .string(target.name))])
            return state.append(
                .transitionItem, item: id, body: body, dependsOn: state.pendingCreates(of: id),
                effect: .state(target, at: at))
        }
    }

    // MARK: Tags and extensions

    func addTag(id: String, tag: String) throws -> QueuedWrite {
        try Checks.tags([tag])
        return try tagged(id, .addTag, tag: tag, body: Self.tags([tag]), .add(tag))
    }

    func removeTag(id: String, tag: String) throws -> QueuedWrite {
        try tagged(id, .removeTag, tag: tag, body: JsonObject(), .remove(tag))
    }

    func replaceMetadata(id: String, tags: [String]) throws -> QueuedWrite {
        try Checks.tags(tags)
        return try tagged(id, .replaceMetadata, tag: nil, body: Self.tags(tags), .replace(tags))
    }

    private func tagged(
        _ id: String, _ kind: WriteKind, tag: String?, body: JsonObject, _ change: InMemoryCore.TagChange
    ) throws -> QueuedWrite {
        try state.withLock { state in
            guard var held = state.items[id] else { throw Refuse.item(id) }
            let before = held.tags.count
            held.tags = Self.applying(change, to: held.tags)
            try Checks.tagCount(before: before, after: held.tags.count)
            state.items[id] = held
            return state.append(
                kind, item: id, tag: tag, body: body, dependsOn: state.pendingCreates(of: id), effect: .tags(change))
        }
    }

    func writeExtension(id: String, namespace: String, body: JsonObject) throws -> QueuedWrite {
        try Properties.cross(body)
        try Properties.keptAsWritten(body)
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
            try Self.refuseUnqueueable(draft, in: state)
            let id = draft.id ?? Minted.id()
            let body = JsonObject(members: [
                .init(key: "id", value: .string(id)), .init(key: "source_id", value: .string(draft.sourceId)),
                .init(key: "target_id", value: .string(draft.targetId)),
                .init(key: "edge_type", value: .string(draft.edgeType)),
                .init(key: "properties", value: .object(draft.properties)),
            ])
            try Properties.refuseTooDeep(body)
            let at = Minted.now()
            let made = Edge(
                id: id, sourceId: draft.sourceId, targetId: draft.targetId, edgeType: draft.edgeType,
                properties: Properties.served(draft.properties), version: 0, createdAt: at, updatedAt: at,
                unreadableProperties: nil)
            state.add(made)
            return state.append(
                .createEdge, item: draft.sourceId, target: draft.targetId, edge: id, body: body,
                dependsOn: state.pendingCreates(of: draft.sourceId, draft.targetId), effect: .madeEdge(made))
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
                try Self.refuseUnwritable(
                    Proposed(
                        edgeType: held.edgeType, source: .held(source ?? held.sourceId),
                        targetId: target ?? held.targetId, replacing: id),
                    in: state)
            }
            try Properties.keptAsWritten(edit.properties)
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
                .updateEdge, item: from, target: to, edge: id, baseVersion: base, body: body, dependsOn: dependsOn,
                effect: .editEdge(properties: edit.properties, source: source, target: target))
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
                .deleteEdge, item: held.sourceId, target: held.targetId, edge: id, body: body, dependsOn: dependsOn,
                effect: .removedEdge)
        }
    }

    static func refuseSelfLoop(_ source: String, _ target: String) throws {
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

    /// The properties of `written` whose value differs from the one `held` has under the same name.
    private static func changed(_ written: JsonObject, from held: JsonObject) -> JsonObject {
        JsonObject(members: written.members.filter { Properties.value(held, $0.key) != $0.value })
    }

    private static func requireFields(of type: ItemType, in properties: JsonObject) throws {
        for field in type.fields where field.required && Properties.value(properties, field.name) == nil {
            throw Refuse.validation("invalid_properties", "\(field.name): Required field is missing")
        }
    }

    /// A null on a field the type declares and does not require is dropped,
    /// and one on any other property is kept.
    private static func droppingOptionalNulls(_ properties: JsonObject, of type: ItemType) -> JsonObject {
        JsonObject(
            members: properties.members.filter { member in
                guard member.value == .null, let field = type.fields.first(where: { $0.name.isBytes(member.key) })
                else {
                    return true
                }
                return field.required
            })
    }

    /// A create's properties as the server holds them: a null on a field the
    /// type declares and does not require is dropped, and the fields the type
    /// declares come first, its ancestors' before its own, then the rest as
    /// given.
    private static func inAnswerOrder(
        _ properties: JsonObject, of type: ItemType, in types: [String: ItemType]
    ) -> JsonObject {
        let kept = properties.members.filter { member in
            guard member.value == .null, let field = type.fields.first(where: { $0.name.isBytes(member.key) }) else {
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
                if let member = kept.first(where: { $0.key.isBytes(field.name) }),
                    !ordered.contains(where: { $0.key.isBytes(field.name) })
                {
                    ordered.append(member)
                }
            }
        }
        return JsonObject(members: ordered + kept.filter { member in !ordered.contains { $0.key.isBytes(member.key) } })
    }

    private static func tags(_ tags: [String]) -> JsonObject {
        JsonObject(members: [JsonMember(key: "tags", value: .array(tags.map { .string($0) }))])
    }

    private static func sorted(_ tags: Set<String>) -> [String] {
        tags.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    static func withoutTags(_ item: Item) -> Item {
        var item = item
        item.tags = []
        return item
    }

    /// A tag change, with tags told apart by their bytes as the core does.
    static func applying(_ change: InMemoryCore.TagChange, to tags: [String]) -> [String] {
        var held = Dictionary(uniqueKeysWithValues: tags.map { (Array($0.utf8), $0) })
        switch change {
        case .add(let tag): held[Array(tag.utf8)] = tag
        case .remove(let tag): held[Array(tag.utf8)] = nil
        case .replace(let tags): held = Dictionary(tags.map { (Array($0.utf8), $0) }) { first, _ in first }
        }
        return held.values.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// The item with the title and body its type's hints name.
    static func derived(_ item: Item, types: [String: ItemType]) -> Item {
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
        tag: String? = nil, baseVersion: Int64? = nil, body: JsonObject, dependsOn: [String],
        effect: InMemoryCore.Effect = .none
    ) -> QueuedWrite {
        let ahead = entries.last {
            $0.inQueue && $0.write.verdict == nil
                && (edge != nil ? $0.write.edgeId == edge : $0.write.edgeId == nil && $0.write.itemId == item)
        }
        let write = QueuedWrite(
            id: Minted.id(), kind: kind, itemId: item, targetId: target, edgeId: edge, namespace: namespace, tag: tag,
            blob: nil, baseVersion: baseVersion, idempotencyKey: Minted.id(), dependsOn: dependsOn,
            follows: ahead?.write.id, verdict: nil, waiting: false, body: body, answer: nil, refusals: 0,
            environmentalStreak: 0, lastFailure: nil, queuedAt: Minted.now(), answeredAt: nil)
        entries.append(InMemoryCore.Entry(write: write, effect: effect))
        return write
    }

    /// Works the rows out again: the seed, then every write that was not refused
    /// or withdrawn, in queue order.
    ///
    /// A row or edge of a create stays at version 0 until the server takes the
    /// create, which makes version 1, and an edit the server takes, of a row or
    /// of an edge, moves it to the next version, while one that waits leaves it
    /// where it was.
    mutating func replay() {
        items = seedItems
        edges = seedEdges
        edgeOrder = seedEdgeOrder
        let types = resolvedItemTypes()
        for entry in entries {
            if entry.withdrawn { continue }
            if case .refused? = entry.write.verdict { continue }
            let write = entry.write
            let taken: Bool =
                switch write.verdict {
                case .accepted?, .merged?: true
                default: false
                }
            switch entry.effect {
            case .none: break
            case .made(var row, let edges):
                if taken { row.version = 1 }
                items[row.id] = row
                for var edge in edges {
                    if taken { edge.version = 1 }
                    add(edge)
                }
            case .edit(let properties, let replacing, let type, let tier, let sourceId, let occurredAt):
                guard let id = write.itemId, var row = items[id] else { continue }
                row.properties = Properties.merged(row.properties, with: properties, replacing: replacing)
                if let type { row.type = type }
                if let tier { row.tier = tier }
                if let sourceId { row.sourceId = sourceId }
                if let occurredAt { row.occurredAt = occurredAt }
                if taken { row.version += 1 }
                items[id] = InMemoryCore.derived(row, types: types)
            case .state(let state, let at):
                guard let id = write.itemId, var row = items[id] else { continue }
                row.move(to: state, at: at)
                items[id] = row
            case .tags(let change):
                guard let id = write.itemId, var row = items[id] else { continue }
                row.tags = InMemoryCore.applying(change, to: row.tags)
                items[id] = row
            case .madeEdge(var edge):
                if taken { edge.version = 1 }
                add(edge)
            case .editEdge(let properties, let source, let target):
                guard let id = write.edgeId, var row = edges[id] else { continue }
                row.properties = Properties.merged(row.properties, with: properties, replacing: false, dropping: false)
                if let source { row.sourceId = source }
                if let target { row.targetId = target }
                if taken { row.version += 1 }
                edges[id] = row
            case .removedEdge:
                guard let id = write.edgeId else { continue }
                edges[id] = nil
                edgeOrder[id] = nil
            }
        }
        for (id, row) in items where declared[row.type] != nil {
            items[id] = InMemoryCore.derived(row, types: types)
        }
    }

    /// Takes the own time out of the create of an item and of every edit waiting behind it, so the server places the
    /// item at its creation time, and shows the create as queued.
    mutating func dropUnsentTime(of id: String) {
        for at in entries.indices {
            guard entries[at].inQueue, entries[at].write.verdict == nil, entries[at].write.itemId == id else {
                continue
            }
            switch entries[at].write.kind {
            case .createItem:
                entries[at].write.body.members.removeAll { $0.key == "occurred_at" }
                if case .made(var row, let edges) = entries[at].effect {
                    row.occurredAt = entries[at].write.queuedAt
                    row.createdAt = entries[at].write.queuedAt
                    entries[at].effect = .made(row, edges: edges)
                }
            case .updateItem:
                entries[at].write.body.members.removeAll { $0.key == "occurred_at" }
                if case .edit(let properties, let replacing, let type, let tier, let sourceId, _) = entries[at].effect {
                    entries[at].effect = .edit(
                        properties: properties, replacing: replacing, type: type, tier: tier, sourceId: sourceId,
                        occurredAt: nil)
                }
            default: break
            }
        }
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

extension WriteKind {
    /// The name the core gives a kind in what it says of a write.
    var name: String {
        switch self {
        case .createItem: "create_item"
        case .updateItem: "update_item"
        case .deleteItem: "delete_item"
        case .restoreItem: "restore_item"
        case .transitionItem: "transition_item"
        case .createEdge: "create_edge"
        case .updateEdge: "update_edge"
        case .deleteEdge: "delete_edge"
        case .replaceMetadata: "replace_metadata"
        case .addTag: "add_tag"
        case .removeTag: "remove_tag"
        case .writeExtension: "write_extension"
        case .deleteExtension: "delete_extension"
        case .uploadBlob: "upload_blob"
        }
    }
}

extension MarfaCore.Item {
    /// Moves the row to `state` made at `at`, as the core records it: a move into the bin takes `at` as the time it
    /// went there, a move out clears it, and a row already in the bin keeps the time it holds.
    mutating func move(to target: ItemState, at: String) {
        if target == .trashed {
            if state != .trashed { trashedAt = at }
        } else if state == .trashed {
            trashedAt = nil
        }
        state = target
    }
}
#endif
