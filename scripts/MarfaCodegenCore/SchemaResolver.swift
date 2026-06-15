import Foundation

/// A schema with its full parent chain resolved: field maps merged, required
/// fields unioned, display hints picked from the nearest ancestor.
public struct ResolvedSchema: Sendable {
    public let id: String
    public let parent: String?
    public let label: String?
    public let description: String?
    public let version: Int
    /// Fields that this schema declares directly.
    public let ownFields: [(key: String, value: CodegenFieldDefinition)]
    /// Fields inherited from ancestors, grouped by the ancestor type id
    /// that owns them (closest ancestor → farthest).
    public let inheritedFieldGroups: [(parentID: String, fields: [(key: String, value: CodegenFieldDefinition)])]
    /// Union of required field names across own + all ancestors.
    public let requiredFields: Set<String>
    public let displayHints: CodegenDisplayHints?

    public var allFieldsOrdered: [(key: String, value: CodegenFieldDefinition)] {
        var out = ownFields
        for group in inheritedFieldGroups {
            out.append(contentsOf: group.fields)
        }
        return out
    }
}

public enum SchemaResolverError: Error, CustomStringConvertible {
    case missingParent(childID: String, parentID: String)
    case circularInheritance(chain: [String])
    case depthExceeded(limit: Int, chain: [String])
    case fieldRedeclared(childID: String, parentID: String, field: String)

    public var description: String {
        switch self {
        case .missingParent(let child, let parent):
            return "type `\(child)` declares parent `\(parent)`, which is not in the schema registry"
        case .circularInheritance(let chain):
            return "circular parent chain: \(chain.joined(separator: " → "))"
        case .depthExceeded(let limit, let chain):
            return "parent chain exceeds the \(limit)-level depth cap: \(chain.joined(separator: " → "))"
        case .fieldRedeclared(let child, let parent, let field):
            return "type `\(child)` redeclares field `\(field)` already defined in ancestor `\(parent)` — remove from child"
        }
    }
}

public enum SchemaResolver {

    public static let maxInheritanceDepth = 10

    /// Resolves `schema` against the combined registry of custom + core types,
    /// flattening inheritance into a single struct definition.
    public static func resolve(
        schema: CodegenTypeSchema,
        registry: [String: CodegenTypeSchema]
    ) throws -> ResolvedSchema {

        // Walk chain
        var chain: [CodegenTypeSchema] = [schema]
        var current = schema
        var visited: Set<String> = [schema.id]

        while let parentID = current.parent {
            if visited.contains(parentID) {
                throw SchemaResolverError.circularInheritance(
                    chain: chain.map(\.id) + [parentID]
                )
            }
            guard let parent = registry[parentID] else {
                throw SchemaResolverError.missingParent(
                    childID: current.id, parentID: parentID
                )
            }
            chain.append(parent)
            visited.insert(parentID)
            current = parent
            if chain.count > maxInheritanceDepth {
                throw SchemaResolverError.depthExceeded(
                    limit: maxInheritanceDepth,
                    chain: chain.map(\.id)
                )
            }
        }

        // Detect field redeclaration between child and any ancestor.
        // (Matches server-side INHERITANCE_VIOLATION behavior.)
        let ancestors = chain.dropFirst()
        for (fieldName, _) in schema.fields.sorted(by: { $0.key < $1.key }) {
            for ancestor in ancestors where ancestor.fields[fieldName] != nil {
                throw SchemaResolverError.fieldRedeclared(
                    childID: schema.id,
                    parentID: ancestor.id,
                    field: fieldName
                )
            }
        }
        // Also check between ancestors (e.g. a grandchild we're resolving
        // could have a clean own-vs-ancestor split, but the ancestor chain
        // itself could be invalid if someone bypassed server validation).
        // Closer-to-leaf wins; far-from-leaf loses.
        var fieldsSeen: Set<String> = []
        var ancestorPurged: [(ancestor: CodegenTypeSchema, fields: [(String, CodegenFieldDefinition)])] = []
        for ancestor in ancestors {
            var kept: [(String, CodegenFieldDefinition)] = []
            for (k, v) in ancestor.fields.sorted(by: { $0.key < $1.key }) where !fieldsSeen.contains(k) {
                kept.append((k, v))
                fieldsSeen.insert(k)
            }
            ancestorPurged.append((ancestor, kept))
        }

        // Required-field union across own + all ancestors
        var required = Set(schema.required)
        for ancestor in ancestors { required.formUnion(ancestor.required) }

        // Display hints — nearest-ancestor-wins
        var hints = schema.displayHints
        if hints == nil {
            for ancestor in ancestors where ancestor.displayHints != nil {
                hints = ancestor.displayHints
                break
            }
        }

        // Own fields, sorted: required first, then alphabetical
        let ownFields = sortedFields(schema.fields, requiredFields: required)

        // Inherited groups, one per ancestor (closest → farthest)
        var inheritedGroups: [(String, [(String, CodegenFieldDefinition)])] = []
        for purged in ancestorPurged where !purged.fields.isEmpty {
            let sorted = sortedFieldPairs(purged.fields, requiredFields: required)
            inheritedGroups.append((purged.ancestor.id, sorted))
        }

        return ResolvedSchema(
            id: schema.id,
            parent: schema.parent,
            label: schema.label,
            description: schema.description,
            version: schema.version,
            ownFields: ownFields,
            inheritedFieldGroups: inheritedGroups,
            requiredFields: required,
            displayHints: hints
        )
    }

    // MARK: - Helpers

    private static func sortedFields(
        _ fields: [String: CodegenFieldDefinition],
        requiredFields: Set<String>
    ) -> [(key: String, value: CodegenFieldDefinition)] {
        sortedFieldPairs(Array(fields), requiredFields: requiredFields)
    }

    private static func sortedFieldPairs(
        _ pairs: [(String, CodegenFieldDefinition)],
        requiredFields: Set<String>
    ) -> [(key: String, value: CodegenFieldDefinition)] {
        pairs.sorted { a, b in
            let aReq = requiredFields.contains(a.0)
            let bReq = requiredFields.contains(b.0)
            if aReq != bReq { return aReq }
            return a.0 < b.0
        }.map { ($0.0, $0.1) }
    }
}
