#if DEBUG
import Foundation
import MarfaCore

/// The refusals the core makes before it queues a write.
///
/// They cover the inputs the fake can judge as the core does. An input it cannot judge throws
/// `FakeCopyError.unsupported` instead of being answered differently.
enum Checks {
    /// The server's `MAX_TAGS_PER_ITEM`.
    static let tagsPerItem = 100

    /// The tags a write carries that the core refuses: every problem, joined as the core joins them.
    static func tags(_ tags: [String]) throws {
        var problems: [String] = tags.count > tagsPerItem ? ["tags: Maximum \(tagsPerItem) tags per item"] : []
        for (position, tag) in tags.enumerated() {
            let problem: String
            if tag.isEmpty {
                problem = "A tag must not be empty"
            } else if tag.unicodeScalars.allSatisfy(isSpace) {
                problem = "A tag must not be blank"
            } else if tag == "." || tag == ".." {
                problem = "A tag must not be \"\(tag)\", which a URL path cannot name"
            } else if tag.utf16.count > 128 {
                problem = "A tag must contain at most 128 UTF-16 code units"
            } else if tag.unicodeScalars.first.map(isSpace) == true || tag.unicodeScalars.last.map(isSpace) == true {
                throw FakeCopyError.unsupported(call: "a tag with surrounding whitespace")
            } else {
                continue
            }
            problems.append("tags[\(position)]: \(problem)")
        }
        if !problems.isEmpty { throw Refuse.validation("validation_error", problems.joined(separator: "; ")) }
    }

    /// A tag write that leaves an item more tags than the bound, refused only where it holds
    /// more than it did, so a row restored over the bound can still shed them.
    static func tagCount(before: Int, after: Int) throws {
        if after > tagsPerItem && after > before {
            throw Refuse.validation(
                "validation_error", "tags: Maximum \(tagsPerItem) tags per item (including existing tags)")
        }
    }

    /// A character JavaScript's `trim` strips.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.properties.isWhitespace && scalar != "\u{85}") || scalar == "\u{FEFF}"
    }

    /// A type the core writes only through its own operation.
    static func writable(_ type: String) throws {
        guard type.hasPrefix("system.") else { return }
        var message = "\(type) is written only through its own operation, never as an item"
        if type == "system.folder" {
            message +=
                ": a folder is written through the folder operations, `device folders create`, `change` and `revoke` on the command line"
        }
        throw MarfaCore.MarfaError.Forbidden(
            code: "type_not_permitted", message: "forbidden (type_not_permitted): \(message)")
    }

    /// The kind of each value against the field its type declares.
    ///
    /// A string field, an enum field that lists its values and a status field are judged with the core's message;
    /// a value the fake cannot judge as the core does, and a body that links, throw `unsupported`. A status
    /// word is judged apart, by ``statusWord(_:of:)``, since the core judges it only where a write changes it.
    static func properties(_ properties: JsonObject, of type: ItemType, call: String) throws {
        for member in properties.members {
            guard let field = type.fields.first(where: { $0.name.isBytes(member.key) }) else { continue }
            if member.value == .null && !field.required { continue }
            let allowed = plain.union(extra[field.fieldType] ?? [])
            if !field.definition.members.allSatisfy({ allowed.contains($0.key) }) {
                throw FakeCopyError.unsupported(call: "\(call) with a constrained \(field.name) field")
            }
            switch field.fieldType {
            case "string", "status":
                if field.fieldType == "status" { _ = try words(of: field, call: call) }
                guard case .string = member.value else {
                    throw Refuse.validation("invalid_properties", "\(field.name): Expected string")
                }
            case "enum":
                try enumValue(member.value, of: field, call: call)
            case "array":
                try list(member.value, of: field, call: call)
            default:
                if !agrees(member.value, with: field.fieldType) {
                    throw FakeCopyError.unsupported(call: "\(call) with a \(field.fieldType) field")
                }
            }
        }
    }

    /// An enum value against the values its field lists, as the core judges it.
    ///
    /// A list the fake cannot quote as the core does, and an enum that lists none, throw `unsupported`.
    private static func enumValue(_ value: JsonValue, of field: TypeField, call: String) throws {
        if let message = try enumMessage(value, definition: field.definition, call: call) {
            throw Refuse.validation("invalid_properties", "\(field.name): \(message)")
        }
    }

    private static func enumMessage(_ value: JsonValue, definition: JsonObject, call: String) throws -> String? {
        guard let listed = Properties.value(definition, "enum_values"), case .array(let entries) = listed,
            !entries.isEmpty
        else { throw FakeCopyError.unsupported(call: "\(call) with an enum field that lists no values") }
        let values = entries.compactMap { entry -> String? in
            guard case .string(let text) = entry, text.unicodeScalars.allSatisfy(quotedAsIs) else { return nil }
            return text
        }
        guard values.count == entries.count else {
            throw FakeCopyError.unsupported(call: "\(call) with an enum field whose values need escaping")
        }
        guard case .string(let text) = value else { return "Expected string" }
        if values.contains(where: { $0.isBytes(text) }) { return nil }
        return "Must be one of \(values.map { "\"\($0)\"" }.joined(separator: ", "))"
    }

    /// The most items a list holds when its field names no `maxItems`.
    private static let itemsPerList = 10_000

    /// A list against the field that declares it.
    ///
    /// Entries are judged only for a list of objects whose members are strings, enums, booleans, integers or
    /// numbers with no constraint beyond the core's defaults; any other list kind, member kind or constraint
    /// throws `unsupported`.
    private static func list(_ value: JsonValue, of field: TypeField, call: String) throws {
        guard case .array(let entries) = value else {
            throw Refuse.validation("invalid_properties", "\(field.name): Expected array")
        }
        if entries.count > itemsPerList {
            throw Refuse.validation("invalid_properties", "\(field.name): Must contain at most \(itemsPerList) items")
        }
        let kind = Properties.string(field.definition, "items_type")
        let members = Properties.value(field.definition, "items_fields")
        if kind == nil && members == nil { return }
        guard kind == "object", case .object(let declared)? = members else {
            throw FakeCopyError.unsupported(call: "\(call) with a \(field.name) list of \(kind ?? "entries")")
        }
        for (index, entry) in entries.enumerated() {
            if let message = try entryMessage(entry, declared: declared, call: call) {
                throw Refuse.validation("invalid_properties", "\(field.name): Item \(index): \(message)")
            }
        }
    }

    /// Why one entry is not one the members allow, in the order the core finds it.
    private static func entryMessage(_ entry: JsonValue, declared: JsonObject, call: String) throws -> String? {
        guard case .object(let held) = entry else { return "Expected object" }
        if held.members.isEmpty { return "Must have at least one member" }
        if let stray = held.members.first(where: { held in !declared.members.contains { $0.key.isBytes(held.key) } }) {
            return "\(stray.key): Is not a member of the entry"
        }
        for member in declared.members {
            guard case .object(let definition) = member.value, let kind = Properties.string(definition, "type") else {
                throw FakeCopyError.unsupported(call: "\(call) with a list member the fake cannot read")
            }
            guard let value = Properties.value(held, member.key) else {
                if case .bool(true)? = Properties.value(definition, "required") { return "\(member.key): Required" }
                continue
            }
            let allowed = plain.union(extra[kind] ?? [])
            guard value != .null, ["string", "enum", "boolean", "integer", "number"].contains(kind),
                definition.members.allSatisfy({ allowed.contains($0.key) })
            else { throw FakeCopyError.unsupported(call: "\(call) with a \(kind) member in a list entry") }
            if let message = try memberMessage(value, kind: kind, definition: definition, call: call) {
                return "\(member.key): \(message)"
            }
        }
        return nil
    }

    private static func memberMessage(
        _ value: JsonValue, kind: String, definition: JsonObject, call: String
    ) throws -> String? {
        switch (kind, value) {
        case ("string", .string(let text)):
            if text.utf16.count > 100_000 { return "Must contain at most 100000 UTF-16 code units" }
            return text.unicodeScalars.contains("\0") ? "Must not contain a null byte (U+0000)" : nil
        case ("string", _): return "Expected string"
        case ("enum", _): return try enumMessage(value, definition: definition, call: call)
        case ("boolean", .bool): return nil
        case ("boolean", _): return "Expected boolean"
        case ("number", .integer), ("number", .number): return nil
        case ("number", _): return "Expected number"
        case ("integer", .integer(let number)):
            return (-9_007_199_254_740_991...9_007_199_254_740_991).contains(number) ? nil : "Expected safe integer"
        case ("integer", .number(let number)):
            return number.rounded() == number && abs(number) <= 9_007_199_254_740_991 ? nil : "Expected safe integer"
        default: return "Expected safe integer"
        }
    }

    /// A character JSON writes as it is.
    private static func quotedAsIs(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar != "\"" && scalar != "\\" && scalar.value != 0x7F
    }

    /// The words a status field lists, each with its group, in order.
    ///
    /// A list the fake cannot read throws `unsupported`.
    static func words(of field: TypeField, call: String) throws -> [(word: String, group: String)] {
        guard let listed = Properties.value(field.definition, "status_values"), case .array(let entries) = listed
        else { throw FakeCopyError.unsupported(call: "\(call) with a status field that lists no words") }
        let words = entries.compactMap { entry -> (word: String, group: String)? in
            guard case .object(let pair) = entry, let word = Properties.string(pair, "value"),
                let group = Properties.string(pair, "group")
            else { return nil }
            return (word, group)
        }
        guard words.count == entries.count, !words.isEmpty else {
            throw FakeCopyError.unsupported(call: "\(call) with a status field whose words it cannot read")
        }
        return words
    }

    /// The word a write sets in the status field of `type`, refused where the type does not declare it.
    ///
    /// `written` is the properties the write changes: the core judges a stored word only where a write changes it
    /// or moves the item, so a word the type no longer declares stands through an edit that leaves it alone.
    static func statusWord(_ written: JsonObject, of type: ItemType, call: String) throws {
        guard let field = type.fields.first(where: { $0.fieldType == "status" }),
            let value = Properties.value(written, field.name), value != .null
        else { return }
        let words = try words(of: field, call: call)
        if case .string(let word) = value, words.contains(where: { $0.word.isBytes(word) }) { return }
        throw Refuse.validation(
            "invalid_properties",
            "\(field.name): Must be a status word the type declares: \(words.map(\.word).joined(separator: ", "))")
    }

    /// A string that links to another item, or embeds a file, in any property of any
    /// type: the core would queue an edge for it, which the fake does not.
    static func links(_ properties: JsonObject, call: String) throws {
        func holds(_ value: JsonValue) -> Bool {
            switch value {
            case .string(let text): text.contains("[[")
            case .array(let items): items.contains(where: holds)
            case .object(let object): object.members.contains { holds($0.value) }
            case .null, .bool, .integer, .number: false
            }
        }
        if properties.members.contains(where: { holds($0.value) }) {
            throw FakeCopyError.unsupported(call: "\(call) with links in a property")
        }
    }

    private static let plain: Set<String> = ["type", "label", "description", "required", "searchable"]

    /// What a field of a kind may hold besides what every field does, which the fake judges.
    private static let extra: [String: Set<String>] = [
        "status": ["status_values"], "enum": ["enum_values"], "array": ["items_type", "items_fields"],
    ]

    private static func agrees(_ value: JsonValue, with kind: String) -> Bool {
        switch (kind, value) {
        case ("number", .number), ("number", .integer), ("integer", .integer), ("boolean", .bool),
            ("array", .array), ("object", .object):
            true
        default: false
        }
    }

    /// What a create names beyond its properties, judged as the core judges it before it queues anything: the
    /// edges it draws, as pairs of edge type and targets in the order the core sends them.
    static func createFields(_ draft: Draft) throws -> [(type: String, targets: [String])] {
        if draft.state == .revoked {
            throw Refuse.validation(
                "validation_error",
                "\(draft.type) cannot start in the revoked state; use active, archived or trashed")
        }
        for (name, value) in [
            ("capture_latitude", draft.captureLatitude), ("capture_longitude", draft.captureLongitude),
        ] {
            if let value, !value.isFinite {
                throw Refuse.validation("validation_error", "\(name) must be a number")
            }
        }
        if (draft.captureLatitude == nil) != (draft.captureLongitude == nil)
            || draft.captureLatitude.map({ abs($0) > 90 }) == true
            || draft.captureLongitude.map({ abs($0) > 180 }) == true
        {
            throw FakeCopyError.unsupported(call: "items.create with a capture location the server may refuse")
        }
        let named = draft.edges.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        for (type, targets) in named {
            if type.isEmpty {
                throw Refuse.notFound(
                    "edge_type_not_found", "edges names an edge type with an empty id, which no edge type has")
            }
            for target in targets {
                if !Minted.isID(target) {
                    throw Refuse.validation("invalid_id", "Invalid edges: \"\(target)\" is not a UUIDv7 in lowercase")
                }
                if draft.id == target {
                    throw Refuse.validation("edge_cycle", "an edge from \(target) to itself closes a cycle")
                }
            }
        }
        return named.filter { !$0.value.isEmpty }.map { (type: $0.key, targets: $0.value) }
    }

    /// A time as the core holds it: UTC, to the millisecond, ending in `Z`.
    ///
    /// Only the forms checked against the core are accepted.
    static func occurred(_ text: String) throws -> String {
        let form =
            /(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{3}))?(Z|[+-]\d{2}:?\d{2}))?/
        guard let match = text.wholeMatch(of: form),
            let year = Int(match.1), let month = Int(match.2), let day = Int(match.3)
        else { throw FakeCopyError.unsupported(call: "an occurredAt of the form \(text)") }
        var parts = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt)
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = match.4.flatMap { Int($0) } ?? 0
        parts.minute = match.5.flatMap { Int($0) } ?? 0
        parts.second = match.6.flatMap { Int($0) } ?? 0
        if parts.hour.map({ $0 >= 24 }) == true {
            throw FakeCopyError.unsupported(call: "an occurredAt of the form \(text)")
        }
        var offset = 0
        if let zone = match.8, zone != "Z" {
            guard let hours = Int(zone.dropFirst().prefix(2)), let minutes = Int(zone.suffix(2)), minutes < 60,
                hours * 60 + minutes <= 14 * 60
            else { throw FakeCopyError.unsupported(call: "an occurredAt of the form \(text)") }
            offset = (zone.hasPrefix("-") ? -1 : 1) * (hours * 3600 + minutes * 60)
        }
        guard let date = parts.date, parts.isValidDate, (parts.hour ?? 0) < 24, (parts.second ?? 0) < 60 else {
            throw FakeCopyError.unsupported(call: "an occurredAt of the form \(text)")
        }
        let utc = Date(timeIntervalSince1970: date.timeIntervalSince1970 - Double(offset))
        let whole = utc.formatted(Date.ISO8601FormatStyle())
        return String(whole.dropLast()) + "." + (match.7.map(String.init) ?? "000") + "Z"
    }
}
#endif
