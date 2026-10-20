#if DEBUG
import Foundation
import MarfaCore
import Synchronization

/// What the core does to a property value, done the same way: the binding's
/// refusals, the form the server answers in, and the limit on a write's depth.
enum Properties {
    /// The deepest nesting the core reads, counting a write's own levels.
    static let depthLimit = 64

    /// The refusals the binding makes before the core sees a value: a number
    /// that is not finite, a key that repeats, and nesting past the limit; then
    /// the core's own refusal of a whole number it would not serve back as
    /// written.
    static func cross(_ object: JsonObject) throws {
        try cross(.object(object), depth: 0)
        try keptAsWritten(.object(object), path: [])
    }

    /// Refuses the first whole number, in document order and at any depth,
    /// that Marfa would serve back with other digits. A number with a fraction
    /// or an exponent names a float and is never judged.
    private static func keptAsWritten(_ value: JsonValue, path: [String]) throws {
        switch value {
        case .integer(let number):
            guard !Integers.kept(number) else { return }
            let served = Integers.served(number).map { ", which it serves as \($0)" } ?? ""
            throw Refuse.validation(
                "invalid_properties",
                "\(path.joined(separator: ".")): Must be a whole number that Marfa serves back with the same digits, not \(number)\(served). Send it as a string."
            )
        case .array(let items):
            for (index, item) in items.enumerated() { try keptAsWritten(item, path: path + [String(index)]) }
        case .object(let object):
            for member in object.members { try keptAsWritten(member.value, path: path + [member.key]) }
        case .null, .bool, .number, .string:
            break
        }
    }

    private static func cross(_ value: JsonValue, depth: Int) throws {
        switch value {
        case .number(let number):
            guard number.isFinite else { throw Refuse.invalid("a number in the JSON is not finite") }
        case .array(let items):
            try nested(depth)
            for item in items { try cross(item, depth: depth + 1) }
        case .object(let object):
            try nested(depth)
            var seen = Set<[UInt8]>()
            for member in object.members {
                try cross(member.value, depth: depth + 1)
                guard seen.insert(Array(member.key.utf8)).inserted else {
                    throw Refuse.invalid("the key \"\(member.key)\" appears twice in one JSON object")
                }
            }
        case .null, .bool, .integer, .string:
            break
        }
    }

    private static func nested(_ depth: Int) throws {
        guard depth < depthLimit else { throw Refuse.invalid("JSON nested deeper than \(depthLimit)") }
    }

    /// Refuses a write whose body nests deeper than the server reads.
    static func refuseTooDeep(_ body: JsonObject) throws {
        guard depth(.object(body)) <= depthLimit else {
            throw Refuse.invalid(
                "a write nests its JSON deeper than \(depthLimit) levels, counting the write's own")
        }
    }

    static func depth(_ value: JsonValue) -> Int {
        switch value {
        case .array(let items): 1 + (items.map(depth).max() ?? 0)
        case .object(let object): 1 + (object.members.map { depth($0.value) }.max() ?? 0)
        case .null, .bool, .integer, .number, .string: 0
        }
    }

    /// Properties as the copy answers them: a whole number is an integer, and
    /// the keys that are array indexes come first, ascending, as JavaScript
    /// orders an object's keys.
    static func served(_ object: JsonObject) -> JsonObject {
        let members = object.members.map { JsonMember(key: $0.key, value: whole($0.value)) }
        let indexed = members.compactMap { member in index(member.key).map { ($0, member) } }
            .sorted { $0.0 < $1.0 }.map(\.1)
        return JsonObject(members: indexed + members.filter { index($0.key) == nil })
    }

    private static func whole(_ value: JsonValue) -> JsonValue {
        switch value {
        case .number(let number):
            if number.rounded() == number, let integer = Int64(exactly: number) { .integer(integer) } else { value }
        case .array(let items): .array(items.map(whole))
        case .object(let object):
            .object(JsonObject(members: object.members.map { JsonMember(key: $0.key, value: whole($0.value)) }))
        case .null, .bool, .integer, .string: value
        }
    }

    private static func index(_ key: String) -> UInt32? {
        guard let index = UInt32(key), index != .max, String(index) == key else { return nil }
        return index
    }

    /// An edit's properties laid over the held ones: a null names a property
    /// the server drops, so it changes nothing.
    static func merged(
        _ held: JsonObject, with edit: JsonObject, replacing: Bool, dropping: Bool = true
    ) -> JsonObject {
        let given = dropping ? edit.members.filter { $0.value != .null } : edit.members
        guard !replacing else { return served(JsonObject(members: given)) }
        var members = held.members
        for member in given {
            if let at = members.firstIndex(where: { $0.key.utf8.elementsEqual(member.key.utf8) }) {
                members[at] = member
            } else {
                members.append(member)
            }
        }
        return served(JsonObject(members: members))
    }

    static func value(_ object: JsonObject, _ key: String) -> JsonValue? {
        object.members.first { $0.key.isBytes(key) }?.value
    }

    static func string(_ object: JsonObject, _ key: String) -> String? {
        if case .string(let text)? = value(object, key) { text } else { nil }
    }

    static func strings(_ object: JsonObject, _ key: String) -> [String] {
        guard case .array(let items)? = value(object, key) else { return [] }
        return items.compactMap { if case .string(let text) = $0 { text } else { nil } }
    }

    static func object(_ object: JsonObject, _ key: String) -> JsonObject? {
        if case .object(let found)? = value(object, key) { found } else { nil }
    }
}

/// Marfa holds a number as a 64-bit float and serves it as JavaScript prints
/// it: the shortest digits that name the float.
enum Integers {
    /// Fewest digits a whole number can have and still be beyond a float's
    /// exact range, 2^53.
    private static let minimumDigits = 16

    /// Whether the number is served back with the digits it was written with.
    static func kept(_ number: Int64) -> Bool {
        let digits = number.magnitude.description
        return digits.count < minimumDigits || served(number) == String(number)
    }

    /// The digits JavaScript prints for the float the number rounds to.
    static func served(_ number: Int64) -> String? {
        let float = Double(number)
        guard float.isFinite else { return nil }
        // Swift prints the shortest digits that name the float, as JavaScript
        // does, but writes a large one with an exponent.
        let text = float.magnitude.description
        let (mantissa, exponent): (Substring, Int) =
            if let mark = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
                (text[..<mark], Int(text[text.index(after: mark)...]) ?? 0)
            } else {
                (text[...], 0)
            }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let whole = parts[0]
        var fraction = parts.count > 1 ? parts[1] : ""
        while fraction.last == "0" { fraction = fraction.dropLast() }
        var digits = String(whole) + fraction
        let places = whole.count + exponent
        guard places >= digits.count else { return nil }
        digits += String(repeating: "0", count: places - digits.count)
        return (float < 0 ? "-" : "") + digits
    }
}

/// The errors the core raises, with the messages it gives them.
enum Refuse {
    static func invalid(_ message: String) -> MarfaCore.MarfaError {
        .Invalid(message: message)
    }

    static func notFound(_ code: String, _ message: String) -> MarfaCore.MarfaError {
        .NotFound(code: code, message: "not found (\(code)): \(message)")
    }

    static func validation(_ code: String, _ message: String) -> MarfaCore.MarfaError {
        .Validation(code: code, message: "validation (\(code)): \(message)")
    }

    static func unknownType(_ message: String) -> MarfaCore.MarfaError {
        .UnknownType(message: "unknown type: \(message)")
    }

    static func item(_ id: String) -> MarfaCore.MarfaError {
        notFound("item_not_found", "\(id) is not a row this copy holds")
    }

    static func edge(_ id: String) -> MarfaCore.MarfaError {
        notFound("edge_not_found", "\(id) is not an edge this copy holds")
    }

    static func write(_ id: String) -> MarfaCore.MarfaError {
        notFound("queued_write_not_found", "\(id) is not a write this queue holds")
    }
}

/// Identifiers and times in the form the core makes them.
enum Minted {
    private struct Last {
        var milliseconds: UInt64 = 0
        var counter: UInt16 = 0
    }

    private static let last = Mutex(Last())

    /// A UUIDv7 that sorts after every one made before it, as the core's do.
    static func id() -> String {
        var bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        let (milliseconds, counter) = last.withLock { last -> (UInt64, UInt16) in
            let now = UInt64(Date.now.timeIntervalSince1970 * 1000)
            if now > last.milliseconds {
                last = Last(milliseconds: now, counter: 0)
            } else if last.counter < 0x0FFF {
                last.counter += 1
            } else {
                last = Last(milliseconds: last.milliseconds + 1, counter: 0)
            }
            return (last.milliseconds, last.counter)
        }
        for position in 0..<6 {
            bytes[position] = UInt8(truncatingIfNeeded: milliseconds >> UInt64(8 * (5 - position)))
        }
        bytes[6] = 0x70 | UInt8(counter >> 8)
        bytes[7] = UInt8(counter & 0xFF)
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }
        return [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]].map { $0.joined() }
            .joined(separator: "-")
    }

    static func isID(_ text: String) -> Bool {
        text.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil
    }

    static func now() -> String {
        Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
#endif

extension String {
    /// Equal as bytes, not as Unicode: `é` and `e` with a combining accent differ, as they do to the core.
    func isBytes(_ other: String) -> Bool { utf8.elementsEqual(other.utf8) }
}
