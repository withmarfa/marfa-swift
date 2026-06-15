import Foundation

// MARK: - Entry point

@main
struct CodegenWire {
    static func main() {
        do {
            let repoRoot = try locateRepoRoot()
            let registryURL = repoRoot.appendingPathComponent("scripts/wire-types.json")
            let registry = try Registry.load(from: registryURL)
            let specURL = repoRoot
                .appendingPathComponent(registry.specPath)
                .standardizedFileURL
            let spec = try loadSpec(specURL)
            let outputDir = repoRoot.appendingPathComponent(registry.outputDir)
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            var generatedFiles: Set<String> = []
            for typeSpec in registry.types.sorted(by: { $0.name < $1.name }) {
                let body = try generateFile(spec: spec, typeSpec: typeSpec, registry: registry)
                let url = outputDir.appendingPathComponent("\(typeSpec.name).swift")
                try body.write(to: url, atomically: true, encoding: .utf8)
                generatedFiles.insert("\(typeSpec.name).swift")
            }

            // Prune any stale files that weren't regenerated this run.
            let existing = try FileManager.default.contentsOfDirectory(
                at: outputDir, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "swift" }
            for url in existing where !generatedFiles.contains(url.lastPathComponent) {
                try FileManager.default.removeItem(at: url)
            }

            FileHandle.standardError.write(
                Data("codegen-wire: wrote \(generatedFiles.count) files to \(outputDir.path)\n".utf8)
            )
        } catch {
            FileHandle.standardError.write(
                Data("codegen-wire: \(error)\n".utf8)
            )
            exit(1)
        }
    }
}

// MARK: - Errors

struct CodegenError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

// MARK: - Registry

struct Registry: Codable {
    let specPath: String
    let outputDir: String
    let numericIntFields: [String]
    let types: [TypeSpec]

    static func load(from url: URL) throws -> Registry {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Registry.self, from: data)
    }
}

struct TypeSpec: Codable {
    let name: String
    let pointer: String
    let conformances: [String]
    let identifiableKey: String?
    let fieldOverrides: [String: String]?
    let enumOverrides: [String: String]?
}

// MARK: - Repo root

func locateRepoRoot() throws -> URL {
    var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<8 {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            return url
        }
        url = url.deletingLastPathComponent()
    }
    throw CodegenError("could not locate Package.swift starting from \(FileManager.default.currentDirectoryPath)")
}

// MARK: - Spec loading

func loadSpec(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CodegenError("openapi.json is not a JSON object at \(url.path)")
    }
    return root
}

// MARK: - JSON Pointer (RFC 6901)

struct JSONPointer {
    let tokens: [String]

    init(_ pointer: String) throws {
        if pointer.isEmpty { tokens = []; return }
        guard pointer.hasPrefix("/") else {
            throw CodegenError("pointer must start with /: \(pointer)")
        }
        let parts = pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        tokens = parts.map { segment in
            segment
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
        }
    }

    func resolve(in root: Any) throws -> Any {
        var current: Any = root
        for (index, token) in tokens.enumerated() {
            if let dict = current as? [String: Any] {
                guard let next = dict[token] else {
                    let path = tokens.prefix(index + 1).joined(separator: "/")
                    throw CodegenError("pointer token '\(token)' not found at /\(path)")
                }
                current = next
            } else if let array = current as? [Any], let idx = Int(token) {
                guard idx < array.count else {
                    throw CodegenError("pointer index \(idx) out of range")
                }
                current = array[idx]
            } else {
                throw CodegenError("pointer cannot descend at token '\(token)'")
            }
        }
        return current
    }
}

// MARK: - Schema normalization

indirect enum SchemaNode {
    case string
    case integer
    case number
    case boolean
    case stringEnum([String])
    case object(properties: [(key: String, schema: SchemaNode, nullable: Bool)], required: Set<String>)
    case array(element: SchemaNode, elementNullable: Bool)
    case freeFormMap
    case constrainedMap(value: SchemaNode, valueNullable: Bool)
}

struct NormalizedSchema {
    let node: SchemaNode
    let isNullable: Bool
}

func normalize(_ raw: Any) throws -> NormalizedSchema {
    guard let dict = raw as? [String: Any] else {
        throw CodegenError("schema is not an object: \(raw)")
    }
    let nullable = (dict["nullable"] as? Bool) ?? false

    if let enumValues = dict["enum"] as? [Any] {
        // String enums become Swift enums. Numeric/other enums fall through
        // to the underlying scalar type (used e.g. for `status: { type:
        // number, enum: [409] }` in the conflict envelope — modeled as Int).
        if enumValues.allSatisfy({ $0 is String }) {
            let strings = enumValues.compactMap { $0 as? String }
            return NormalizedSchema(node: .stringEnum(strings), isNullable: nullable)
        }
    }

    let type = dict["type"] as? String

    switch type {
    case "string":
        return NormalizedSchema(node: .string, isNullable: nullable)
    case "integer":
        return NormalizedSchema(node: .integer, isNullable: nullable)
    case "number":
        return NormalizedSchema(node: .number, isNullable: nullable)
    case "boolean":
        return NormalizedSchema(node: .boolean, isNullable: nullable)
    case "array":
        guard let items = dict["items"] else {
            throw CodegenError("array schema missing 'items'")
        }
        let inner = try normalize(items)
        return NormalizedSchema(
            node: .array(element: inner.node, elementNullable: inner.isNullable),
            isNullable: nullable
        )
    case "object":
        return try normalizeObject(dict, nullable: nullable)
    case nil:
        // Loose object with additionalProperties but no explicit type, treat as freeform.
        if dict["additionalProperties"] != nil {
            return try normalizeObject(dict, nullable: nullable)
        }
        // Bare schema used as a freeform value (e.g. additionalProperties: { nullable: true }).
        return NormalizedSchema(node: .freeFormMap, isNullable: nullable)
    default:
        throw CodegenError("unsupported schema type: \(type ?? "nil")")
    }
}

func normalizeObject(_ dict: [String: Any], nullable: Bool) throws -> NormalizedSchema {
    if let additional = dict["additionalProperties"] {
        if let addDict = additional as? [String: Any] {
            if addDict.isEmpty || (addDict["nullable"] as? Bool == true && addDict["type"] == nil) {
                return NormalizedSchema(node: .freeFormMap, isNullable: nullable)
            }
            let inner = try normalize(additional)
            return NormalizedSchema(
                node: .constrainedMap(value: inner.node, valueNullable: inner.isNullable),
                isNullable: nullable
            )
        } else if let flag = additional as? Bool, flag == false {
            // Closed object with no additionalProperties — fall through to property walk.
        }
    }

    let propsDict = (dict["properties"] as? [String: Any]) ?? [:]
    let required = Set((dict["required"] as? [String]) ?? [])
    var entries: [(key: String, schema: SchemaNode, nullable: Bool)] = []
    for key in propsDict.keys.sorted() {
        let inner = try normalize(propsDict[key]!)
        entries.append((key: key, schema: inner.node, nullable: inner.isNullable))
    }
    return NormalizedSchema(
        node: .object(properties: entries, required: required),
        isNullable: nullable
    )
}

// MARK: - Emission

struct EmitContext {
    var pendingStructs: [(name: String, node: SchemaNode, required: Set<String>)] = []
    var pendingEnums: [(name: String, cases: [String])] = []
}

func generateFile(spec: [String: Any], typeSpec: TypeSpec, registry: Registry) throws -> String {
    let pointer = try JSONPointer(typeSpec.pointer)
    let raw = try pointer.resolve(in: spec)
    let normalized = try normalize(raw)
    guard case let .object(properties, required) = normalized.node else {
        throw CodegenError("\(typeSpec.name) pointer does not resolve to an object schema")
    }

    var context = EmitContext()
    let body = renderStruct(
        name: typeSpec.name,
        properties: properties,
        required: required,
        typeSpec: typeSpec,
        registry: registry,
        context: &context
    )

    // Drain pending siblings (deterministic by name).
    var rendered = body
    while !context.pendingStructs.isEmpty || !context.pendingEnums.isEmpty {
        let nextEnums = context.pendingEnums.sorted { $0.name < $1.name }
        context.pendingEnums.removeAll()
        for pending in nextEnums {
            rendered += "\n" + renderEnum(name: pending.name, cases: pending.cases)
        }
        let nextStructs = context.pendingStructs.sorted { $0.name < $1.name }
        context.pendingStructs.removeAll()
        for pending in nextStructs {
            rendered += "\n" + renderStruct(
                name: pending.name,
                properties: extractProperties(pending.node),
                required: pending.required,
                typeSpec: siblingSpec(named: pending.name, parent: typeSpec),
                registry: registry,
                context: &context
            )
        }
    }

    return header(for: typeSpec) + rendered
}

func siblingSpec(named name: String, parent: TypeSpec) -> TypeSpec {
    TypeSpec(
        name: name,
        pointer: "",
        conformances: ["Codable", "Sendable", "Hashable"],
        identifiableKey: nil,
        fieldOverrides: nil,
        enumOverrides: nil
    )
}

func extractProperties(_ node: SchemaNode) -> [(key: String, schema: SchemaNode, nullable: Bool)] {
    if case let .object(properties, _) = node {
        return properties
    }
    return []
}

func header(for typeSpec: TypeSpec) -> String {
    """
    // Code generated by codegen-wire; DO NOT EDIT.
    // Source: scripts/openapi.json (snapshot of monorepo spec)
    // Pointer: \(typeSpec.pointer)
    // To regenerate: `./scripts/sync-openapi.sh` (or `swift run codegen-wire` if the snapshot is current).

    import Foundation


    """
}

struct ResolvedField {
    let jsonKey: String
    let swiftProp: String
    let swiftType: String
    let needsCodingKey: Bool
}

func renderStruct(
    name: String,
    properties: [(key: String, schema: SchemaNode, nullable: Bool)],
    required: Set<String>,
    typeSpec: TypeSpec,
    registry: Registry,
    context: inout EmitContext
) -> String {
    var fields: [ResolvedField] = []
    for prop in properties {
        let optional = !required.contains(prop.key) || prop.nullable
        let inner = resolveType(
            node: prop.schema,
            parent: name,
            fieldName: prop.key,
            typeSpec: typeSpec,
            registry: registry,
            context: &context
        )
        let swiftType = optional ? "\(inner)?" : inner
        let camel = toCamelCase(prop.key)
        let swiftProp = escapeSwiftIdentifier(camel)
        // CodingKey is needed when (a) the JSON key differs from the
        // unescaped camelCase name, or (b) the Swift identifier had to be
        // backticked (force explicit mapping for clarity).
        fields.append(ResolvedField(
            jsonKey: prop.key,
            swiftProp: swiftProp,
            swiftType: swiftType,
            needsCodingKey: camel != prop.key || swiftProp != camel
        ))
    }

    let conformanceOrder = ["Codable", "Sendable", "Hashable", "Identifiable"]
    let conformances = conformanceOrder.filter { typeSpec.conformances.contains($0) }
    let conformanceList = conformances.joined(separator: ", ")

    var out = "public struct \(name): \(conformanceList) {\n"
    for field in fields {
        out += "    public let \(field.swiftProp): \(field.swiftType)\n"
    }

    out += "\n"
    out += renderInit(name: name, fields: fields)

    if fields.contains(where: { $0.needsCodingKey }) {
        out += "\n"
        out += renderCodingKeys(fields: fields)
    }

    out += "}\n"
    return out
}

func renderInit(name: String, fields: [ResolvedField]) -> String {
    guard !fields.isEmpty else {
        return "    public init() {}\n"
    }
    var out = "    public init(\n"
    for (index, field) in fields.enumerated() {
        let comma = index == fields.count - 1 ? "" : ","
        let defaultSuffix = field.swiftType.hasSuffix("?") ? " = nil" : ""
        out += "        \(field.swiftProp): \(field.swiftType)\(defaultSuffix)\(comma)\n"
    }
    out += "    ) {\n"
    for field in fields {
        out += "        self.\(field.swiftProp) = \(field.swiftProp)\n"
    }
    out += "    }\n"
    return out
}

func renderCodingKeys(fields: [ResolvedField]) -> String {
    var out = "    enum CodingKeys: String, CodingKey {\n"
    for field in fields {
        if field.needsCodingKey {
            out += "        case \(field.swiftProp) = \"\(field.jsonKey)\"\n"
        } else {
            out += "        case \(field.swiftProp)\n"
        }
    }
    out += "    }\n"
    return out
}

func renderEnum(name: String, cases: [String]) -> String {
    var out = "public enum \(name): String, Codable, Sendable, Hashable {\n"
    for value in cases.sorted() {
        let swiftCase = toCamelCase(value)
        if swiftCase == value {
            out += "    case \(swiftCase)\n"
        } else {
            out += "    case \(swiftCase) = \"\(value)\"\n"
        }
    }
    out += "}\n"
    return out
}

// MARK: - Type resolution

func resolveType(
    node: SchemaNode,
    parent: String,
    fieldName: String,
    typeSpec: TypeSpec,
    registry: Registry,
    context: inout EmitContext
) -> String {
    if let override = typeSpec.fieldOverrides?[fieldName] {
        return override
    }
    if let override = typeSpec.enumOverrides?[fieldName] {
        switch node {
        case .string, .stringEnum(_):
            return override
        case .constrainedMap(let valueNode, let valueNullable):
            // Map-of-stringEnum: route the value type through the override and
            // register the shared enum exactly once.
            if case let .stringEnum(values) = valueNode {
                registerSharedEnum(name: override, cases: values, context: &context)
                let wrapped = valueNullable ? "\(override)?" : override
                return "[String: \(wrapped)]"
            }
        default:
            break
        }
    }

    switch node {
    case .string:
        return "String"
    case .integer:
        return "Int"
    case .number:
        return registry.numericIntFields.contains(fieldName) ? "Int" : "Double"
    case .boolean:
        return "Bool"
    case .stringEnum(let values):
        let siblingName = parent + pascal(fieldName)
        context.pendingEnums.append((name: siblingName, cases: values))
        return siblingName
    case .array(let element, let elementNullable):
        let inner = resolveType(
            node: element,
            parent: parent,
            fieldName: fieldName + "Item",
            typeSpec: typeSpec,
            registry: registry,
            context: &context
        )
        let wrapped = elementNullable ? "\(inner)?" : inner
        return "[\(wrapped)]"
    case .freeFormMap:
        return "[String: JSONValue]"
    case .constrainedMap(let valueNode, let valueNullable):
        let inner = resolveType(
            node: valueNode,
            parent: parent,
            fieldName: fieldName + "Value",
            typeSpec: typeSpec,
            registry: registry,
            context: &context
        )
        let wrapped = valueNullable ? "\(inner)?" : inner
        return "[String: \(wrapped)]"
    case .object(_, let required):
        let siblingName = parent + pascal(fieldName)
        context.pendingStructs.append((name: siblingName, node: node, required: required))
        return siblingName
    }
}

/// Register a sibling enum by canonical name, deduping repeat registrations.
/// Used by `enumOverrides` so that several fields can share the same enum
/// declaration in the generated file.
func registerSharedEnum(
    name: String,
    cases: [String],
    context: inout EmitContext
) {
    if context.pendingEnums.contains(where: { $0.name == name }) { return }
    context.pendingEnums.append((name: name, cases: cases))
}

// MARK: - Naming helpers

/// Swift keywords that must be backticked when used as property or case names.
/// JSON property names that round-trip as Swift identifiers go through this
/// list; CodingKeys still emit the raw JSON key as the string mapping.
let reservedSwiftKeywords: Set<String> = [
    "default", "class", "struct", "enum", "protocol", "extension", "func",
    "var", "let", "init", "deinit", "self", "super", "case", "switch", "if",
    "else", "for", "while", "do", "try", "catch", "throw", "throws",
    "return", "break", "continue", "guard", "defer", "in", "is", "as",
    "true", "false", "nil", "where", "operator", "import", "associatedtype",
    "typealias", "fileprivate", "internal", "private", "public", "open",
    "static", "final", "lazy", "weak", "unowned", "convenience", "override",
    "required", "mutating", "nonmutating", "repeat", "fallthrough",
    "rethrows", "async", "await", "any", "some", "Type", "inout",
]

func toCamelCase(_ snake: String) -> String {
    let parts = snake.split(whereSeparator: { $0 == "_" || $0 == "-" })
    guard let first = parts.first else { return snake }
    var result = String(first).lowercased()
    for segment in parts.dropFirst() {
        result += segment.capitalized(firstOnly: true)
    }
    return result
}

/// Wraps a Swift identifier in backticks if it collides with a language
/// keyword. Used in property declarations, init signatures, and CodingKeys
/// case labels — never in CodingKeys raw-string mappings (those carry the
/// original JSON key).
func escapeSwiftIdentifier(_ name: String) -> String {
    reservedSwiftKeywords.contains(name) ? "`\(name)`" : name
}

func pascal(_ snake: String) -> String {
    let parts = snake.split(whereSeparator: { $0 == "_" || $0 == "-" })
    return parts.map { $0.capitalized(firstOnly: true) }.joined()
}

extension Substring {
    func capitalized(firstOnly: Bool) -> String {
        guard let first = self.first else { return String(self) }
        return first.uppercased() + self.dropFirst().lowercased()
    }
}

extension String {
    func capitalized(firstOnly: Bool) -> String {
        guard let first = self.first else { return self }
        return first.uppercased() + self.dropFirst().lowercased()
    }
}
