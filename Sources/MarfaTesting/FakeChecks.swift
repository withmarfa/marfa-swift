#if DEBUG
import Foundation
import MarfaCore

/// The refusals the core makes before it queues a write.
///
/// They cover the inputs the fake can judge as the core does. An input it cannot judge throws
/// `FakeCopyError.unsupported` instead of being answered differently.
enum Checks {
    /// A tag the core refuses, by its position in the list.
    static func tags(_ tags: [String]) throws {
        for (position, tag) in tags.enumerated() {
            if tag.isEmpty { throw Refuse.validation("validation_error", "tags[\(position)]: A tag must not be empty") }
            if tag.unicodeScalars.allSatisfy(isSpace) {
                throw Refuse.validation("validation_error", "tags[\(position)]: A tag must not be blank")
            }
            if tag.utf16.count > 128 {
                throw Refuse.validation(
                    "validation_error", "tags[\(position)]: A tag must contain at most 128 UTF-16 code units")
            }
            if tag.unicodeScalars.first.map(isSpace) == true || tag.unicodeScalars.last.map(isSpace) == true {
                throw FakeCopyError.unsupported(call: "a tag with surrounding whitespace")
            }
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
    /// Only a string field is judged with the core's message; a value the fake cannot
    /// judge as the core does, and a body that links, throw `unsupported`.
    static func properties(_ properties: JsonObject, of type: ItemType, call: String) throws {
        for member in properties.members {
            guard let field = type.fields.first(where: { $0.name == member.key }) else { continue }
            if member.value == .null && !field.required { continue }
            if !field.definition.members.allSatisfy({ plain.contains($0.key) }) {
                throw FakeCopyError.unsupported(call: "\(call) with a constrained \(field.name) field")
            }
            if field.fieldType == "string" {
                guard case .string = member.value else {
                    throw Refuse.validation("invalid_properties", "\(field.name): Expected string")
                }
            } else if !agrees(member.value, with: field.fieldType) {
                throw FakeCopyError.unsupported(call: "\(call) with a \(field.fieldType) field")
            }
        }
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

    private static let plain: Set<String> = ["type", "description", "required", "searchable"]

    private static func agrees(_ value: JsonValue, with kind: String) -> Bool {
        switch (kind, value) {
        case ("number", .number), ("number", .integer), ("integer", .integer), ("boolean", .bool),
            ("array", .array), ("object", .object):
            true
        default: false
        }
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
