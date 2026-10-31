#if DEBUG
import Foundation
import MarfaCore

/// What a view write answered, kept under its idempotency key.
enum ViewAnswer: Sendable {
    case row(ViewRow)
    case deleted
}

/// Saved views, held as `system.view` items and written at once, never queued.
extension InMemoryCore {
    static let viewType = "system.view"
    private static let ownFields: Set<String> = [
        "title", "created_at", "updated_at", "occurred_at", "type", "state", "tier", "tags",
    ]
    private static let dateFields: Set<String> = ["created_at", "updated_at", "occurred_at"]

    // MARK: Writes

    func createView(settings: JsonObject, idempotencyKey: String?) throws -> ViewRow {
        try state.withLock { state in
            let replay = idempotencyKey.map { "POST views|\($0)" }
            if let replay, case .row(let first)?? = state.viewAnswers[replay] { return first }
            guard Properties.string(settings, "title") != nil else {
                throw Refuse.validation("missing_required_field", "title is required")
            }
            try Self.check(settings)
            let at = Minted.now()
            let properties = Properties.served(settings)
            let item = Item(
                id: Minted.id(), type: Self.viewType, properties: properties, state: .active, tier: .library,
                version: 1, schemaVersion: 1, source: "device", sourceId: nil, occurredAt: at, createdAt: at,
                updatedAt: at, tags: [], title: Properties.string(properties, "title"), body: nil)
            let row = Self.hold(item, in: &state)
            if let replay { state.viewAnswers[replay] = .row(row) }
            return row
        }
    }

    func changeView(id: String, changes: JsonObject, version: Int64, idempotencyKey: String?) throws -> ViewRow {
        try state.withLock { state in
            let replay = idempotencyKey.map { "PATCH views/\(id)|\($0)" }
            if let replay, case .row(let first)?? = state.viewAnswers[replay] { return first }
            if Properties.value(changes, "version") != nil {
                throw Refuse.invalid("a view's version is the one the change is based on, not a setting")
            }
            guard !changes.members.isEmpty else {
                throw Refuse.validation("validation_error", "a change names at least one setting")
            }
            try Self.check(changes)
            guard let held = state.items[id], held.type == Self.viewType else {
                throw Refuse.notFound("item_not_found", "\(id) is not a view")
            }
            guard held.state == .active else {
                throw Refuse.validation("invalid_transition", "the view \(id) is \(held.state.name) and cannot change")
            }
            var named = changes.members
            if version != held.version {
                guard let base = state.viewSettings[id]?[version], version < held.version else {
                    throw FakeCopyError.unsupported(call: "changeView based on a version the fake never held")
                }
                // A setting equal to the base version's is an echo, and a clear of a group the base lacked
                // changes nothing: neither collides nor applies.
                named.removeAll {
                    $0.value == .null
                        ? $0.key == "group" && Properties.value(base, "group") == nil
                        : Properties.value(base, $0.key) == $0.value
                }
                let collided = named.map(\.key).filter {
                    Properties.value(base, $0) != Properties.value(held.properties, $0)
                }
                if !collided.isEmpty {
                    throw MarfaError.Server(
                        status: 409, code: "version_conflict",
                        message:
                            "version_conflict: the view changed since version \(version): \(collided.joined(separator: ", "))"
                    )
                }
            }
            if named.isEmpty
                || (named.count == 1 && named[0].key == "group" && named[0].value == .null
                    && Properties.value(held.properties, "group") == nil)
            {
                throw FakeCopyError.unsupported(call: "changeView that changes nothing")
            }
            var members = held.properties.members
            for member in named {
                let removed =
                    member.value == .null || (member.key == "sort" && member.value == .array([]))
                if let at = members.firstIndex(where: { $0.key == member.key }) {
                    if removed { members.remove(at: at) } else { members[at] = member }
                } else if !removed {
                    members.append(member)
                }
            }
            var item = held
            item.properties = Properties.served(JsonObject(members: members))
            item.title = Properties.string(item.properties, "title")
            item.version = held.version + 1
            item.updatedAt = Minted.now()
            let row = Self.hold(item, in: &state)
            if let replay { state.viewAnswers[replay] = .row(row) }
            return row
        }
    }

    func deleteView(id: String, idempotencyKey: String?) throws {
        try state.withLock { state in
            let replay = idempotencyKey.map { "DELETE views/\(id)|\($0)" }
            if let replay, case .deleted?? = state.viewAnswers[replay] { return }
            guard let held = state.items[id], held.type == Self.viewType else {
                throw Refuse.notFound("item_not_found", "\(id) is not a view")
            }
            state.items[held.id] = nil
            state.seedItems[held.id] = nil
            state.viewSettings[held.id] = nil
            if let replay { state.viewAnswers[replay] = .deleted }
        }
    }

    /// Holds the item where a replay of the queue keeps it, and answers it.
    private static func hold(_ item: Item, in state: inout State) -> ViewRow {
        state.items[item.id] = item
        state.seedItems[item.id] = item
        state.viewSettings[item.id, default: [:]][item.version] = item.properties
        return ViewRow(id: item.id, version: item.version, state: item.state, settings: item.properties)
    }

    /// The refusals the server makes of a setting, for the parts the fake can judge.
    ///
    /// A `filter` is stored as given: only a read that must evaluate it can refuse it.
    private static func check(_ settings: JsonObject) throws {
        if let title = Properties.value(settings, "title"), case .string(let text) = title {
            if text.isEmpty {
                throw Refuse.validation("validation_error", "title: Too small: expected string to have >=1 characters")
            }
            if text.utf16.count > 500 {
                throw Refuse.validation("validation_error", "title: Must contain at most 500 UTF-16 code units")
            }
        }
        if case .object(let query)? = Properties.value(settings, "query") {
            let types = Properties.strings(query, "types")
            if types.count > 100 {
                throw Refuse.validation("validation_error", "query.types: Too big: expected array to have <=100 items")
            }
            if Properties.value(query, "state") != nil && Properties.strings(query, "state").isEmpty {
                throw Refuse.validation(
                    "validation_error", "query.state: Too small: expected array to have >=1 items")
            }
            for (index, name) in types.enumerated() {
                if !Declaring.isTypeIdentifier(name) {
                    throw Refuse.validation(
                        "validation_error", "query.types.\(index): Invalid type identifier: \(name)")
                }
                if name.hasPrefix("system.") {
                    throw Refuse.validation(
                        "validation_error",
                        "query.types.\(index): \(name) is a system type, which no item door writes")
                }
            }
            for state in Properties.strings(query, "state") where state != "active" && state != "archived" {
                throw Refuse.validation("validation_error", "query.state: \(state) is not active or archived")
            }
            if let beneath = Properties.string(query, "beneath"), !isItemId(beneath) {
                throw Refuse.validation("validation_error", "query.beneath: Invalid item id: \(beneath)")
            }
        }
        if case .array(let keys)? = Properties.value(settings, "sort") {
            if keys.count > 10 { throw Refuse.validation("validation_error", "sort: at most 10 keys") }
            for (index, key) in keys.enumerated() {
                guard case .object(let key) = key else { continue }
                let by = Properties.string(key, "by") ?? ""
                if !isField(by, edges: false) {
                    throw Refuse.validation("validation_error", "sort.\(index).by: \(by) is not a field")
                }
            }
        }
        if case .object(let group)? = Properties.value(settings, "group") {
            let by = Properties.string(group, "by") ?? ""
            if !isField(by, edges: true) {
                throw Refuse.validation("validation_error", "group.by: \(by) is not a field")
            }
            for name in ["order", "hidden"] where values(group, name).count > 1000 {
                throw Refuse.validation(
                    "validation_error", "group.\(name): Too big: expected array to have <=1000 items")
            }
            if Properties.value(group, "bucket") != nil && !isDate(by) {
                throw Refuse.validation("validation_error", "group.bucket: \(by) is not a date field")
            }
        }
    }

    private static func isDate(_ field: String) -> Bool {
        dateFields.contains(field) || field.hasPrefix("properties.")
    }

    private static func property(_ field: String) -> String? {
        guard field.hasPrefix("properties.") else { return nil }
        let name = String(field.dropFirst("properties.".count))
        func letter(_ byte: UInt8) -> Bool {
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
        }
        let bytes = Array(name.utf8)
        let ok =
            bytes.first.map(letter) == true && bytes.allSatisfy { letter($0) || ($0 >= 0x30 && $0 <= 0x39) }
        return ok ? name : nil
    }

    private static func isItemId(_ text: String) -> Bool {
        text.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil
    }

    private static func edgeReference(_ field: String) -> (backref: Bool, type: String)? {
        for (prefix, backref) in [("edge[", false), ("backref[", true)]
        where field.hasPrefix(prefix) && field.hasSuffix("]") {
            let name = String(field.dropFirst(prefix.count).dropLast())
            if !name.isEmpty && !name.contains(where: { $0 == "[" || $0 == "]" || $0.isWhitespace }) {
                return (backref, name)
            }
        }
        return nil
    }

    private static func isField(_ field: String, edges: Bool) -> Bool {
        ownFields.contains(field) || property(field) != nil || (edges && edgeReference(field) != nil)
    }

    // MARK: Reads

    func listViews() throws -> Views {
        state.withLock { state in
            let held = state.items.values.filter { $0.type == Self.viewType }
                .sorted { Self.precedes($0, $1, by: (.createdAt, .descending)) }
            return Views(views: held.map(Self.row), completeness: .complete)
        }
    }

    func view(id: String) throws -> ViewRow? {
        try state.withLock { state in
            guard let item = state.items[id], item.state != .trashed else { return nil }
            guard item.type == Self.viewType else {
                throw Refuse.invalid("\(id) is a \(item.type), not a \(Self.viewType)")
            }
            return Self.row(item)
        }
    }

    private static func row(_ item: Item) -> ViewRow {
        ViewRow(id: item.id, version: item.version, state: item.state, settings: item.properties)
    }

    func listInView(id: String, limit: UInt32?, offset: UInt32?) throws -> Listing {
        try state.withLock { state in
            let (view, matched) = try Self.scope(id, in: state, call: "items.list(inView:)")
            let types = state.resolvedItemTypes()
            let keys = try Self.sortKeys(view.settings)
            var found = matched.map { item in (item, keys.map { Self.sortKey(item, $0.by, types) }) }
            found.sort { Self.precedes($0, $1, by: keys) }
            var items = found.map(\.0)
            let skip = Int(offset ?? 0)
            items = skip < items.count ? Array(items.dropFirst(skip)) : []
            if let limit { items = Array(items.prefix(Int(limit))) }
            return Listing(items: items, completeness: .complete)
        }
    }

    // MARK: Scope

    static func scope(_ id: String, in state: State, call: String) throws -> (ViewRow, [Item]) {
        guard let held = state.items[id], held.state != .trashed else {
            throw Refuse.notFound(
                "not_held", "view \(id) is not held in this working copy: pin it or hydrate with \(viewType)")
        }
        guard held.type == viewType else { throw Refuse.invalid("\(id) is a \(held.type), not a \(viewType)") }
        let view = row(held)
        guard view.state == .active else { throw Refuse.invalid("a revoked view cannot be evaluated") }
        let query = Properties.object(view.settings, "query") ?? JsonObject()
        var states: [String] = ["active", "archived"]
        if Properties.value(query, "state") != nil {
            states = Properties.strings(query, "state")
            if states.isEmpty || states.contains(where: { $0 != "active" && $0 != "archived" }) {
                throw Refuse.invalid("a view query names active or archived states")
            }
        }
        let named = Properties.strings(query, "types").map { $0.trimmingCharacters(in: .whitespaces) }
        let roots: [String]? =
            named.isEmpty || named.contains("*") ? nil : try named.compactMap { try Self.root(of: $0) }
        let tier = Properties.string(query, "tier").map(wireTier) ?? .all
        if Properties.value(query, "filter") != nil {
            throw FakeCopyError.unsupported(call: "\(call) with a filter")
        }
        let beneath = Properties.string(query, "beneath").map { state.reached(from: $0) }
        let types = state.resolvedItemTypes()
        let matched = state.items.values.filter { item in
            if item.type.hasPrefix("system.") || !states.contains(item.state.name) { return false }
            if let roots, !roots.contains(where: { reaches(item.type, $0, in: types) }) { return false }
            switch tier {
            case .all: break
            case .library: if item.tier != .library { return false }
            case .feed: if item.tier != .feed { return false }
            }
            if let beneath, !beneath.contains(item.id) { return false }
            return true
        }
        return (view, matched)
    }

    private static func wireTier(_ text: String) -> SliceTier {
        switch text {
        case "library": .library
        case "feed": .feed
        default: .all
        }
    }

    // MARK: Order

    private typealias Key = PropertyKey

    private static func sortKeys(_ settings: JsonObject) throws -> [(by: String, ascending: Bool)] {
        guard case .array(let keys)? = Properties.value(settings, "sort"), !keys.isEmpty else { return [] }
        guard keys.count <= 10 else { throw Refuse.invalid("a view accepts at most 10 sort keys") }
        return try keys.map { key in
            guard case .object(let key) = key, let by = Properties.string(key, "by") else {
                throw Refuse.invalid("a sort key requires by")
            }
            switch Properties.string(key, "direction") {
            case "asc": return (by, true)
            case "desc": return (by, false)
            default: throw Refuse.invalid("a sort direction is asc or desc")
            }
        }
    }

    private static func text(_ value: String) -> Key { .text(Array(value.utf8)) }

    private static func sortKey(_ item: Item, _ field: String, _ types: [String: ItemType]) -> Key? {
        switch field {
        case "created_at": return text(item.createdAt)
        case "updated_at": return text(item.updatedAt)
        case "occurred_at": return text(item.occurredAt)
        case "type": return text(item.type)
        case "state": return text(item.state.name)
        case "tier": return item.tier.map { text($0.name) }
        case "title": return propertyKey(item, types[item.type]?.titleField ?? "title")
        case "tags":
            return item.tags.min { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map(text)
        default: return property(field).flatMap { propertyKey(item, $0) }
        }
    }

    /// The core's order: a missing key last whatever the direction, ties on the item id, which follows the
    /// direction only when the single key is a timestamp.
    private static func precedes(
        _ lhs: (Item, [Key?]), _ rhs: (Item, [Key?]), by keys: [(by: String, ascending: Bool)]
    ) -> Bool {
        if keys.isEmpty {
            if lhs.0.occurredAt != rhs.0.occurredAt { return lhs.0.occurredAt > rhs.0.occurredAt }
            return lhs.0.id > rhs.0.id
        }
        for (index, key) in keys.enumerated() {
            switch (lhs.1[index], rhs.1[index]) {
            case (nil, nil): continue
            case (nil, _): return false
            case (_, nil): return true
            case (let left?, let right?):
                if left == right { continue }
                return key.ascending ? left < right : right < left
            }
        }
        let timestamp = keys.count == 1 && ["occurred_at", "created_at", "updated_at"].contains(keys[0].by)
        return timestamp && !keys[0].ascending ? lhs.0.id > rhs.0.id : lhs.0.id < rhs.0.id
    }

    // MARK: Groups

    func viewGroups(id: String, timeZone: String?) throws -> ViewGroups {
        try state.withLock { state in
            let zone: TimeZone?
            if let timeZone {
                guard let found = TimeZone(identifier: timeZone) else {
                    throw Refuse.invalid("unknown time zone \"\(timeZone)\"")
                }
                zone = found
            } else {
                zone = nil
            }
            let (view, matched) = try Self.scope(id, in: state, call: "items.groups(inView:)")
            let group = Properties.object(view.settings, "group")
            let by = group.flatMap { Properties.string($0, "by") }
            let bucket = group.flatMap { Properties.string($0, "bucket") }
            if let bucket {
                guard ["day", "week", "month", "year"].contains(bucket) else {
                    throw Refuse.invalid("unknown date bucket")
                }
                guard let by, Self.isDate(by) else { throw Refuse.invalid("a date bucket requires a date field") }
            }
            if let by, !Self.isField(by, edges: true) { throw Refuse.invalid("unsupported view field \"\(by)\"") }
            let types = state.resolvedItemTypes()
            var counts: [String: ViewGroup] = [:]
            for item in matched {
                for var key in try Self.groupKeys(item, by, state, types) {
                    if let bucket { key = try Self.bucketed(key, bucket, zone) }
                    let identity = Self.identity(key)
                    counts[identity, default: ViewGroup(key: key, count: 0)].count += 1
                }
            }
            let hidden = Set(Self.values(group, "hidden").map(Self.identity))
            var rank: [String: Int] = [:]
            for (index, key) in Self.values(group, "order").enumerated() where rank[Self.identity(key)] == nil {
                rank[Self.identity(key)] = index
            }
            let groups = counts.values.filter { !hidden.contains(Self.identity($0.key)) }.sorted { lhs, rhs in
                let left = rank[Self.identity(lhs.key)] ?? Int.max
                let right = rank[Self.identity(rhs.key)] ?? Int.max
                return left == right ? Self.keyPrecedes(lhs.key, rhs.key) : left < right
            }
            return ViewGroups(groups: groups, completeness: .complete)
        }
    }

    private static func values(_ group: JsonObject?, _ name: String) -> [JsonValue] {
        if let group, case .array(let items)? = Properties.value(group, name) { items } else { [] }
    }

    private static func scalar(_ value: JsonValue?) -> JsonValue {
        switch value {
        case .integer?, .number?, .bool?, .string?: value ?? .null
        default: .null
        }
    }

    private static func groupKeys(_ item: Item, _ by: String?, _ state: State, _ types: [String: ItemType]) throws
        -> [JsonValue]
    {
        guard let by else { return [.null] }
        switch by {
        case "created_at": return [.string(item.createdAt)]
        case "updated_at": return [.string(item.updatedAt)]
        case "occurred_at": return [.string(item.occurredAt)]
        case "type": return [.string(item.type)]
        case "state": return [.string(item.state.name)]
        case "tier": return [item.tier.map { .string($0.name) } ?? .null]
        case "tags": return item.tags.isEmpty ? [.null] : item.tags.map { .string($0) }
        case "title": return [scalar(Properties.value(item.properties, types[item.type]?.titleField ?? "title"))]
        default:
            if let name = property(by) { return [scalar(Properties.value(item.properties, name))] }
            guard let reference = edgeReference(by) else { throw Refuse.invalid("unsupported view field \"\(by)\"") }
            var others: [String] = []
            for edge in state.edgesInOrder where edge.edgeType == reference.type {
                let (own, other) = reference.backref ? (edge.targetId, edge.sourceId) : (edge.sourceId, edge.targetId)
                if own == item.id && !others.contains(other) { others.append(other) }
            }
            return others.isEmpty ? [.null] : others.map { .string($0) }
        }
    }

    private static func identity(_ value: JsonValue) -> String {
        switch value {
        case .integer(let number): return "number:\(Double(number))"
        case .number(let number): return "number:\(number == 0 ? 0 : number)"
        case .string(let text): return "string:\(text)"
        case .bool(let flag): return "bool:\(flag)"
        case .null: return "null"
        case .array, .object: return "json:\(value)"
        }
    }

    private static func keyPrecedes(_ lhs: JsonValue, _ rhs: JsonValue) -> Bool {
        func rank(_ value: JsonValue) -> Int {
            switch value {
            case .bool, .integer, .number: 0
            case .string: 1
            default: 2
            }
        }
        func number(_ value: JsonValue) -> Double {
            switch value {
            case .integer(let number): Double(number)
            case .number(let number): number
            case .bool(let flag): flag ? 1 : 0
            default: 0
            }
        }
        if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
        if case .string(let left) = lhs, case .string(let right) = rhs {
            return left.utf8.lexicographicallyPrecedes(right.utf8)
        }
        if number(lhs) != number(rhs) { return number(lhs) < number(rhs) }
        return identity(lhs) < identity(rhs)
    }

    /// The first day of the span a date falls in, as `YYYY-MM-DD`, or `null` for a value that is no date.
    private static func bucketed(_ key: JsonValue, _ bucket: String, _ zone: TimeZone?) throws -> JsonValue {
        guard case .string(let text) = key else { return .null }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var day: DateComponents
        if text.utf8.count == 10, let plain = Dates.plain(text) {
            day = utc.dateComponents([.year, .month, .day], from: plain)
        } else if let instant = Dates.instant(text) {
            var local = Calendar(identifier: .gregorian)
            local.timeZone = zone ?? .current
            day = local.dateComponents([.year, .month, .day], from: instant)
        } else {
            throw FakeCopyError.unsupported(call: "items.groups(inView:) of a date in the form \"\(text)\"")
        }
        guard var date = utc.date(from: day) else { return .null }
        switch bucket {
        case "week":
            let fromMonday = (utc.component(.weekday, from: date) + 5) % 7
            date = utc.date(byAdding: .day, value: -fromMonday, to: date) ?? date
        case "month":
            day = utc.dateComponents([.year, .month], from: date)
            date = utc.date(from: day) ?? date
        case "year":
            day = utc.dateComponents([.year], from: date)
            date = utc.date(from: day) ?? date
        default: break
        }
        return .string(date.formatted(Dates.day))
    }
}

private enum Dates {
    static let day = Date.ISO8601FormatStyle().year().month().day()

    static func plain(_ text: String) -> Date? { try? Date(text, strategy: day) }

    static func instant(_ text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle()))
    }
}
#endif
