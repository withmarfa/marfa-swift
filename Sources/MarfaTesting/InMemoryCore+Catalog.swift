import Foundation
import MarfaCore

extension InMemoryCore {
    func itemTypes() throws -> [ItemType] {
        state.withLock { state in
            state.resolvedItemTypes().values.sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
        }
    }

    func itemType(id: String) throws -> ItemType {
        try state.withLock { state in
            guard let type = state.resolvedItemTypes()[id] else {
                throw Refuse.notFound("type_not_found", "the catalog this copy holds has no type \(id)")
            }
            return type
        }
    }

    func edgeTypes() throws -> [EdgeType] {
        state.withLock { state in
            state.edgeTypes.values.sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
        }
    }

    func edgeType(id: String) throws -> EdgeType {
        try state.withLock { state in
            guard let type = state.edgeTypes[id] else {
                throw Refuse.notFound("edge_type_not_found", "the catalog this copy holds has no edge type \(id)")
            }
            return type
        }
    }

    func declareTypes(types: [JsonObject]) throws {
        let ids = Set(types.compactMap { Properties.string($0, "id") })
        try state.withLock { state in
            let known = ids.union(state.givenItemTypes.keys)
            var rows: [String: JsonObject] = [:]
            for definition in types {
                let (id, row) = try Declaring.declaration(definition, known: known)
                rows[id] = row
            }
            state.declared = rows
        }
    }

    func declaredTypes() throws -> [JsonObject] {
        state.withLock { state in
            state.declared.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }.map(\.value)
        }
    }
}

extension InMemoryCore.State {
    /// The types the copy was given, and the ones the app declared, which take
    /// the place of a given type of the same id.
    func resolvedItemTypes() -> [String: ItemType] {
        var types = givenItemTypes
        for id in declared.keys {
            if let type = Declaring.resolve(id, declared: declared, given: givenItemTypes) { types[id] = type }
        }
        return types
    }
}

/// The rules for the types an app declares, as the core holds them to.
enum Declaring {
    private static let shippedRoots = ["core", "system", "marfa"]

    private static let reservedRoots = [
        "app", "audit", "blobs", "config", "connectors", "content", "core", "edge", "grants", "instance", "items",
        "keys", "marfa", "metadata", "profile", "schema", "space", "system", "user", "webhooks",
    ]

    private static let fieldTypes = [
        "string", "number", "integer", "boolean", "url", "email", "datetime", "date", "enum", "array", "object",
        "thumbnail",
    ]

    private static let grammar =
        "a type is two or more lowercase dotted segments, each a letter followed by letters, digits, hyphens and "
        + "underscores, at most 128 characters, with exactly three under `app.` and none under a root Marfa reserves"

    /// A type identifier, or a namespace under `.*`.
    static func isTypePattern(_ name: String) -> Bool {
        func segment(_ part: Substring) -> Bool {
            guard let first = part.first, first.isASCII, first.isLowercase else { return false }
            return part.dropFirst().allSatisfy {
                ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" || $0 == "_"
            }
        }
        guard name.utf8.count <= 128 else { return false }
        if name.hasSuffix(".*") {
            let root = name.dropLast(2)
            return !root.isEmpty && root.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(segment)
        }
        let segments = name.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2, segments.allSatisfy(segment) else { return false }
        switch segments[0] {
        case "app": return segments.count == 3
        case "core", "system", "user", "marfa": return true
        case let root: return !reservedRoots.contains(String(root))
        }
    }

    /// A declaration as the core keeps it: the empty `fields` and the
    /// `version` a registration needs filled in where the app left them out.
    static func declaration(_ definition: JsonObject, known: Set<String>) throws -> (String, JsonObject) {
        guard let id = Properties.string(definition, "id") else {
            throw Refuse.invalid("a type to declare names its id")
        }
        guard !id.hasSuffix(".*"), isTypePattern(id) else {
            throw Refuse.invalid("not a type to declare: \"\(id)\"; \(grammar)")
        }
        guard !shippedRoots.contains(String(id.split(separator: ".")[0])) else {
            throw Refuse.invalid(
                "\(id) is Marfa's, and an app declares types under its own namespace: `app.`, `user.` or a name of its own"
            )
        }
        var row = definition
        switch Properties.value(definition, "fields") {
        case nil:
            row.members.append(JsonMember(key: "fields", value: .object(JsonObject())))
        case .object(let fields)?:
            for member in fields.members {
                guard case .object(let field) = member.value, let kind = Properties.string(field, "type") else {
                    throw Refuse.invalid("\(id) declares \(member.key) with no type")
                }
                guard fieldTypes.contains(kind) else {
                    throw Refuse.invalid(
                        "\(id) declares \(member.key) as \"\(kind)\", which is not a field type: one of "
                            + fieldTypes.joined(separator: ", "))
                }
            }
        case .some:
            throw Refuse.invalid("the fields of \(id) are an object by name")
        }
        if Properties.value(row, "version") == nil {
            row.members.append(JsonMember(key: "version", value: .integer(0)))
        }
        if let parent = Properties.string(row, "parent"), parent != id, !known.contains(parent) {
            throw Refuse.invalid(
                "\(id) names the parent \(parent), which is neither a type Marfa ships nor one declared")
        }
        return (id, row)
    }

    /// A declared type with the fields it inherits, as `GET /types/{id}` would
    /// answer it; a declared type's hints are the nearest set a type in its
    /// chain declares, taken whole.
    static func resolve(
        _ id: String, declared: [String: JsonObject], given: [String: ItemType], depth: Int = 0
    ) -> ItemType? {
        guard depth < 64 else { return nil }
        guard let row = declared[id] else { return given[id] }
        let parent = Properties.string(row, "parent").flatMap { $0 == id ? nil : $0 }
        let inherited = parent.flatMap { resolve($0, declared: declared, given: given, depth: depth + 1) }
        var fields = Dictionary(uniqueKeysWithValues: (inherited?.fields ?? []).map { ($0.name, $0) })
        for member in Properties.object(row, "fields")?.members ?? [] {
            guard case .object(let definition) = member.value else { continue }
            var required = false
            if case .bool(true)? = Properties.value(definition, "required") { required = true }
            fields[member.key] = TypeField(
                name: member.key, fieldType: Properties.string(definition, "type") ?? "", required: required,
                description: Properties.string(definition, "description"), declaredBy: id, definition: definition)
        }
        let hints = Properties.object(row, "display_hints")
        var version: Int64 = 0
        switch Properties.value(row, "version") {
        case .integer(let integer)?: version = integer
        case .number(let number)?: version = Int64(exactly: number.rounded(.towardZero)) ?? 0
        default: break
        }
        return ItemType(
            id: id, label: Properties.string(row, "label"), description: Properties.string(row, "description"),
            parent: parent, version: version,
            fields: fields.values.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) },
            titleField: hints.map { Properties.string($0, "title_field") } ?? inherited?.titleField,
            bodyField: hints.map { Properties.string($0, "body_field") } ?? inherited?.bodyField,
            linkField: Properties.string(row, "link_field"), roles: Properties.strings(row, "roles"),
            compatibleWith: Properties.strings(row, "compatible_with"))
    }
}
