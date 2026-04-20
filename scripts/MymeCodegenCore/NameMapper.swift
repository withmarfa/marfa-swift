import Foundation

/// Canonical set of Swift keywords we refuse to emit as bare identifiers.
/// Sourced from the Swift language reference; keeps emitted code buildable
/// when a custom schema contains fields like `init`, `class`, or `description`.
let swiftKeywords: Set<String> = [
    // Declarations
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
    "func", "import", "init", "inout", "internal", "let", "open", "operator",
    "private", "precedencegroup", "protocol", "public", "rethrows", "static",
    "struct", "subscript", "typealias", "var",
    // Statements
    "break", "case", "catch", "continue", "default", "defer", "do", "else",
    "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw",
    "switch", "where", "while",
    // Expressions / types
    "Any", "as", "catch", "false", "is", "nil", "super", "self", "Self",
    "throw", "throws", "true", "try",
]

/// Identifiers the SDK already publishes that a custom struct name must not
/// collide with. Keep in sync with public `MymeSDK` types.
let sdkReservedStructNames: Set<String> = [
    "Item", "MymeItem", "JSONValue", "MymeClient", "ClientConfiguration",
    "CreateItemInput", "UpdateOptions", "ListFilters", "SearchFilters",
    "Origin", "ItemState", "FieldDefinition", "TypeSchema", "EdgeSchema",
    "MymeError", "Transport", "HTTPMethod", "SSEEvent",
    "ConflictResponse", "ConflictResult",
]

public enum NameMapperError: Error, CustomStringConvertible, Equatable {
    case emptyID
    case invalidID(String)
    case collision(structName: String, ids: [String])
    case sdkReservedCollision(structName: String, typeID: String)

    public var description: String {
        switch self {
        case .emptyID: return "type id is empty"
        case .invalidID(let id): return "type id `\(id)` is not a valid Myme type identifier"
        case .collision(let name, let ids):
            let joined = ids.map { "`\($0)`" }.joined(separator: ", ")
            return "type ids \(joined) all map to Swift struct name `\(name)` — rename one of them"
        case .sdkReservedCollision(let name, let id):
            return "type id `\(id)` maps to Swift struct name `\(name)`, which collides with a public MymeSDK type — rename"
        }
    }
}

public enum NameMapper {

    // MARK: - Type names

    /// Converts a dotted type ID to its Swift struct name.
    /// Examples: `core.note` → `CoreNote`, `myapp.media.book` → `MyappMediaBook`.
    /// Segments are split on `.` and `_`; each becomes PascalCase.
    public static func structName(for typeID: String) throws -> String {
        guard !typeID.isEmpty else { throw NameMapperError.emptyID }
        let segments = typeID.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.allSatisfy({ !$0.isEmpty }) else {
            throw NameMapperError.invalidID(typeID)
        }
        let parts = segments.flatMap { $0.split(separator: "_", omittingEmptySubsequences: true) }
        let joined = parts.map { titleCase(String($0)) }.joined()
        guard !joined.isEmpty else { throw NameMapperError.invalidID(typeID) }
        // Prepend `_` if the first character is a digit (valid identifier rule).
        let first = joined.first!
        if first.isNumber {
            return "_" + joined
        }
        return joined
    }

    /// Converts a snake_case property name to lowerCamelCase.
    /// Keeps all-lowercase names as-is.
    public static func propertyName(for fieldKey: String) -> String {
        let parts = fieldKey.split(separator: "_", omittingEmptySubsequences: true)
        guard let first = parts.first else { return fieldKey }
        let head = String(first)
        let tail = parts.dropFirst().map { titleCase(String($0)) }.joined()
        return head + tail
    }

    /// Wraps a property name in backticks if it collides with a Swift
    /// keyword. Always safe — `\`init\`` parses as an identifier.
    public static func escaped(_ name: String) -> String {
        if swiftKeywords.contains(name) {
            return "`\(name)`"
        }
        return name
    }

    /// Runs the struct-name mapper over all type IDs, detecting collisions
    /// and SDK-reserved clashes. Returns `[typeID: structName]`.
    public static func buildNameMap(for typeIDs: [String]) throws -> [String: String] {
        var mapping: [String: String] = [:]
        var reverse: [String: [String]] = [:]
        for id in typeIDs {
            let name = try structName(for: id)
            if sdkReservedStructNames.contains(name) {
                throw NameMapperError.sdkReservedCollision(structName: name, typeID: id)
            }
            mapping[id] = name
            reverse[name, default: []].append(id)
        }
        for (name, ids) in reverse where ids.count > 1 {
            throw NameMapperError.collision(structName: name, ids: ids.sorted())
        }
        return mapping
    }

    // MARK: - Helpers

    private static func titleCase(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
