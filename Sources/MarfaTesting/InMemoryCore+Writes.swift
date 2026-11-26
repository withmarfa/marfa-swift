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
            try Self.refuseUnwritable(
                edges.flatMap { named in
                    named.targets.map { target in
                        Proposed(
                            edgeType: named.type, from: .made(id: id, type: draft.type), toId: target,
                            replacing: nil)
                    }
                },
                in: state)
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
                        id: Self.projectedEdgeID(id, named.type, target), fromId: id, toId: target,
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
        if edit.exact { throw FakeCopyError.unsupported(call: "items.update(exact:)") }
        try Properties.cross(edit.properties)
        try Checks.links(edit.properties, call: "items.update")
        try Properties.keptAsWritten(edit.properties)
        let cleared = try Self.cleared(edit.clearProperties, setting: edit.properties)
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
            // Version 0 is how this copy shows its own create until the server takes it, so an editor can still hold
            // the item as read there. Once the create is taken the edit goes on the version it made; until then it
            // stays on 0 and waits behind it. A create that was refused or withdrawn made nothing.
            let ownCreate = asRead && edit.baseVersion == 0 && held.version > 0
            let base: Int64 = ownCreate && state.tookOwnCreate(of: id) ? 1 : edit.baseVersion
            let behindOwnCreate = ownCreate && base == 0 && !state.pendingCreates(of: id).isEmpty
            let readEarlier = asRead && (base > 0 || behindOwnCreate) && base <= held.version
            guard base == held.version || readEarlier else {
                throw Refuse.invalid(
                    "the update to \(id) is based on version \(base) and this copy holds version \(held.version); read it again"
                )
            }
            if let type = edit.type { try Self.refuseRetypeBreakingEdges(of: id, to: type, in: state) }
            // Judged on any version: whatever the server holds by then, the field ends up empty.
            if let target = types[edit.type ?? held.type] {
                let required = cleared.filter { name in
                    target.fields.contains { $0.required && $0.name.isBytes(name) }
                }
                if !required.isEmpty {
                    throw Refuse.validation(
                        "invalid_properties", required.map { "\($0): Required" }.joined(separator: "; "))
                }
            }
            var body = JsonObject(members: [
                JsonMember(key: "properties", value: .object(edit.properties)),
                JsonMember(key: "version", value: .integer(base)),
            ])
            if edit.replaceProperties { body.members.append(.init(key: "properties_mode", value: .string("replace"))) }
            if !cleared.isEmpty {
                body.members.append(.init(key: "clear_properties", value: .array(cleared.map(JsonValue.string))))
            }
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
            held.properties = Properties.merged(
                held.properties, with: edit.properties, replacing: replacing, clearing: cleared)
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
                    properties: edit.properties, replacing: replacing, cleared: cleared, type: retype, tier: tier,
                    sourceId: edit.sourceId,
                    occurredAt: shownTime))
        }
    }

    /// The id the core gives the edge it shows from a create that waits, which the same create always shows again.
    static func projectedEdgeID(_ from: String, _ edgeType: String, _ to: String) -> String {
        var hash = SHA256()
        for part in [from, edgeType, to] {
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

    func transitionItem(id: String, state target: ItemState, from: ItemState?) throws -> QueuedWrite {
        if target == .revoked {
            throw Refuse.validation(
                "validation_error",
                "state: a device cannot move \(id) to the revoked state; it is reachable only on a reserved type and on the server's authority"
            )
        }
        return try state.withLock { state in
            guard var held = state.items[id] else { throw Refuse.item(id) }
            try Checks.writable(held.type)
            if let from, from != held.state {
                throw Refuse.validation(
                    "state_conflict", "\(id) is \(held.state.name), not \(from.name)",
                    details: Refuse.details(["expected": .string(from.name), "actual": .string(held.state.name)]))
            }
            let body = JsonObject(members: [
                JsonMember(key: "state", value: .string(target.name)),
                JsonMember(key: "from", value: .string(held.state.name)),
            ])
            let at = Minted.now()
            held.move(to: target, at: at)
            state.items[id] = held
            return state.append(
                .transitionItem, item: id, body: body, dependsOn: state.pendingCreates(of: id),
                effect: .state(target, at: at))
        }
    }

    // MARK: Tags and extensions

    func addTag(id: String, tag: String) throws -> QueuedWrite {
        try Checks.tags([tag])
        return try tagged(id, .addTag, tag: tag, .add(tag)) { _ in Self.tags([tag]) }
    }

    func removeTag(id: String, tag: String) throws -> QueuedWrite {
        try tagged(id, .removeTag, tag: tag, .remove(tag)) { _ in JsonObject() }
    }

    func replaceTags(id: String, tags: [String]) throws -> QueuedWrite {
        try Checks.tags(tags)
        return try tagged(id, .replaceTags, tag: nil, .replace(tags)) { read in
            var body = Self.tags(tags)
            body.members.append(JsonMember(key: "read_tags", value: .array(read.map { .string($0) })))
            return body
        }
    }

    /// `body` answers the write's payload from the tags the copy held before the change.
    private func tagged(
        _ id: String, _ kind: WriteKind, tag: String?, _ change: InMemoryCore.TagChange,
        body: ([String]) -> JsonObject
    ) throws -> QueuedWrite {
        try state.withLock { state in
            guard var held = state.items[id] else { throw Refuse.item(id) }
            let read = held.tags
            let before = held.tags.count
            held.tags = Self.applying(change, to: held.tags)
            try Checks.tagCount(before: before, after: held.tags.count)
            state.items[id] = held
            return state.append(
                kind, item: id, tag: tag, body: body(read), dependsOn: state.pendingCreates(of: id),
                effect: .tags(change))
        }
    }

    /// The fake holds no extension namespace, so it cannot tell a revision stale: like the core, it keeps the
    /// write whole and leaves the answer to the verdict chooser, which stands for the server.
    func writeExtension(id: String, namespace: String, body: JsonObject, readRevision: String?) throws -> QueuedWrite {
        try Self.refuseEmpty(namespace, readRevision)
        try Properties.cross(body)
        try Properties.keptAsWritten(body)
        return try state.withLock { state in
            guard state.items[id] != nil else { throw Refuse.item(id) }
            try Properties.refuseTooDeep(body)
            return state.append(
                .writeExtension, item: id, namespace: namespace, body: body, dependsOn: state.pendingCreates(of: id))
        }
    }

    func deleteExtension(id: String, namespace: String, readRevision: String?) throws -> QueuedWrite {
        try Self.refuseEmpty(namespace, readRevision)
        return try state.withLock { state in
            guard state.items[id] != nil else { throw Refuse.item(id) }
            return state.append(
                .deleteExtension, item: id, namespace: namespace, body: JsonObject(),
                dependsOn: state.pendingCreates(of: id))
        }
    }

    private static func refuseEmpty(_ namespace: String, _ readRevision: String?) throws {
        if namespace.isEmpty {
            throw Refuse.invalid("an extension write names no namespace, and the namespace is where it goes")
        }
        if readRevision?.isEmpty == true {
            throw Refuse.invalid(
                "an extension write names an empty read revision; name the revision a read of the namespace "
                    + "answered, or none")
        }
    }

    // MARK: Edges

    func createEdge(draft: EdgeDraft) throws -> QueuedWrite {
        try Properties.cross(draft.properties)
        return try state.withLock { state in
            try Self.refuseUnqueueable(draft, in: state)
            let id = draft.id ?? Minted.id()
            let body = JsonObject(members: [
                .init(key: "id", value: .string(id)), .init(key: "from_id", value: .string(draft.fromId)),
                .init(key: "to_id", value: .string(draft.toId)),
                .init(key: "edge_type", value: .string(draft.edgeType)),
                .init(key: "properties", value: .object(draft.properties)),
            ])
            try Properties.refuseTooDeep(body)
            let at = Minted.now()
            let made = Edge(
                id: id, fromId: draft.fromId, toId: draft.toId, edgeType: draft.edgeType,
                properties: Properties.served(draft.properties), version: 0, createdAt: at, updatedAt: at,
                unreadableProperties: nil)
            state.add(made)
            return state.append(
                .createEdge, item: draft.fromId, target: draft.toId, edge: id, body: body,
                dependsOn: state.pendingCreates(of: draft.fromId, draft.toId), effect: .madeEdge(made))
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
            let (movedFrom, movedTo) = Self.endsMoved(held, edit.moves)
            try Self.refuseMove(of: held, from: movedFrom, to: movedTo, in: state)
            try Properties.keptAsWritten(edit.properties)
            guard !edit.properties.members.isEmpty || movedFrom != nil || movedTo != nil else { return nil }
            var body = JsonObject(members: [
                .init(key: "properties", value: .object(edit.properties)), .init(key: "version", value: .integer(base)),
            ])
            if let movedFrom { body.members.append(.init(key: "from_id", value: .string(movedFrom))) }
            if let movedTo { body.members.append(.init(key: "to_id", value: .string(movedTo))) }
            try Properties.refuseTooDeep(body)
            var dependsOn = state.pendingCreate(ofEdge: id)
            let waiting = state.pendingCreates(of: [movedFrom, movedTo].compactMap { $0 })
            for waited in waiting where !dependsOn.contains(waited) {
                dependsOn.append(waited)
            }
            let (from, to) = (held.fromId, held.toId)
            var members = held.properties.members
            for member in edit.properties.members {
                if let at = members.firstIndex(where: { $0.key.utf8.elementsEqual(member.key.utf8) }) {
                    members[at] = member
                } else {
                    members.append(member)
                }
            }
            held.properties = Properties.served(JsonObject(members: members))
            if let movedFrom { held.fromId = movedFrom }
            if let movedTo { held.toId = movedTo }
            state.edges[id] = held
            return state.append(
                .updateEdge, item: from, target: to, edge: id, baseVersion: base, body: body, dependsOn: dependsOn,
                effect: .editEdge(properties: edit.properties, from: movedFrom, to: movedTo))
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
                .deleteEdge, item: held.fromId, target: held.toId, edge: id, body: body, dependsOn: dependsOn,
                effect: .removedEdge)
        }
    }

    // MARK: Shared

    /// The properties of `written` whose value differs from the one `held` has under the same name.
    private static func changed(_ written: JsonObject, from held: JsonObject) -> JsonObject {
        JsonObject(members: written.members.filter { Properties.value(held, $0.key) != $0.value })
    }

    /// The names an edit clears, once each in the order given, refused as the core refuses them: an empty name, and
    /// one the same edit also sets.
    private static func cleared(_ names: [String], setting properties: JsonObject) throws -> [String] {
        var problems: [String] = []
        if names.contains(where: \.isEmpty) { problems.append("clear_properties: A property name must not be empty") }
        let both = names.filter { name in properties.members.contains { $0.key.isBytes(name) } }
        if !both.isEmpty {
            problems.append("A property can't be both set and cleared: \(both.joined(separator: ", "))")
        }
        if !problems.isEmpty { throw Refuse.validation("validation_error", problems.joined(separator: "; ")) }
        var once: [String] = []
        for name in names where !once.contains(where: { $0.isBytes(name) }) { once.append(name) }
        return once
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

    static func withoutTags(_ item: Item) -> Item {
        var item = item
        item.tags = []
        return item
    }

    /// A tag change, with tags told apart by their bytes and kept in the order they were added, as the core does.
    static func applying(_ change: InMemoryCore.TagChange, to tags: [String]) -> [String] {
        func unique(_ tags: [String]) -> [String] {
            var seen = Set<[UInt8]>()
            return tags.filter { seen.insert(Array($0.utf8)).inserted }
        }
        switch change {
        case .add(let tag): return unique(tags + [tag])
        case .remove(let tag): return tags.filter { !$0.isBytes(tag) }
        case .replace(let tags): return unique(tags)
        }
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
            id: Minted.id(), kind: kind, itemId: item, toId: target, edgeId: edge, namespace: namespace, tag: tag,
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
            case .edit(let properties, let replacing, let cleared, let type, let tier, let sourceId, let occurredAt):
                guard let id = write.itemId, var row = items[id] else { continue }
                row.properties = Properties.merged(
                    row.properties, with: properties, replacing: replacing, clearing: cleared)
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
            case .editEdge(let properties, let from, let to):
                guard let id = write.edgeId, var row = edges[id] else { continue }
                row.properties = Properties.merged(row.properties, with: properties, replacing: false, dropping: false)
                if let from { row.fromId = from }
                if let to { row.toId = to }
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
                if case .edit(let properties, let replacing, let cleared, let type, let tier, let sourceId, _) =
                    entries[at].effect
                {
                    entries[at].effect = .edit(
                        properties: properties, replacing: replacing, cleared: cleared, type: type, tier: tier,
                        sourceId: sourceId, occurredAt: nil)
                }
            default: break
            }
        }
    }

    /// Whether the server answered this copy's own create of `id` accepted or merged.
    ///
    /// The answer stays in the entries after the queue forgets it, as the core keeps the version the create made.
    func tookOwnCreate(of id: String) -> Bool {
        entries.contains { entry in
            guard !entry.withdrawn, entry.write.kind == .createItem, entry.write.itemId == id,
                entry.write.baseVersion.map({ $0 == 0 }) ?? true
            else { return false }
            switch entry.write.verdict {
            case .accepted?, .merged?: return true
            default: return false
            }
        }
    }

    /// The creates of these items that the server has not taken: unanswered, blocked or dead.
    ///
    /// A write sent past one is refused, so it waits behind it.
    func pendingCreates(of ids: String...) -> [String] {
        pendingCreates(of: ids)
    }

    func pendingCreates(of ids: [String]) -> [String] {
        var found: [String] = []
        for id in ids {
            for entry in entries
            where entry.inQueue && entry.write.kind == .createItem && entry.write.itemId == id
                && !found.contains(entry.write.id)
            {
                switch entry.write.verdict {
                case nil, .blocked?, .dead?: found.append(entry.write.id)
                default: break
                }
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
        case .replaceTags: "replace_tags"
        case .addTag: "add_tag"
        case .removeTag: "remove_tag"
        case .writeExtension: "write_extension"
        case .deleteExtension: "delete_extension"
        case .uploadBlob: "upload_blob"
        case .writeRows: "write_rows"
        case .undoRows: "undo_rows"
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
