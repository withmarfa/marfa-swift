import Foundation

/// The type graph, on the device.
///
/// **Why this exists at all.** A client with a local store accepted any type
/// string and validated nothing, so a write the type forbids was queued, sent,
/// and refused by the server — possibly hours later, on a reconnect, long
/// after the person who could have fixed it moved on. A write that only fails
/// on reconnect fails at the wrong time.
///
/// **What it is not.** It is not the server's validator reimplemented. It
/// mirrors the rules the server applies by default: an unknown type is
/// refused, a required field must be present and well-typed, and a declared
/// field must hold what it declares. Unknown properties pass, because the
/// server passes them — it validates with a loose object unless a space has
/// turned on strict enforcement for that type, which is a per-space setting
/// the device does not hold. A write only strict mode would refuse is still
/// refused by the server, and the queue's one-refresh-then-permanent rule is
/// what carries that case.
///
/// Stating that boundary rather than implying parity is deliberate: a local
/// check advertised as equivalent, which is merely similar, is worse than one
/// whose limits are written down.
public struct MarfaTypeRegistry: Sendable {
    private let definitions: [String: MarfaTypeDefinition]

    /// The types the SDK ships with — every `core.*` and `system.*` type in
    /// the platform registry at the version this build was generated against.
    public static let platform = MarfaTypeRegistry(definitions: PlatformTypeRegistry.definitions)

    public init(definitions: [String: MarfaTypeDefinition]) {
        self.definitions = definitions
    }

    /// Every type this registry knows, sorted for stable output.
    public var typeIds: [String] { definitions.keys.sorted() }

    public func definition(for typeId: String) -> MarfaTypeDefinition? {
        definitions[typeId]
    }

    /// A registry holding this one's types plus `overlay`'s, with `overlay`
    /// winning on collision.
    ///
    /// This is how a space's custom types join the platform set. Overlay wins
    /// because a space may re-register a type id the platform also declares,
    /// and the space's copy is the one its rows were written against.
    public func merging(_ overlay: [String: MarfaTypeDefinition]) -> MarfaTypeRegistry {
        MarfaTypeRegistry(definitions: definitions.merging(overlay) { _, new in new })
    }

    /// Every definition flattened against the graph, the way the server
    /// flattens one when it is asked for it.
    ///
    /// **`GET /types` answers with schemas as declared**, so a type reaching
    /// the device through the cache carries its own fields and a `parent` id
    /// and nothing more. A validator run against that refuses nothing a
    /// parent required, which is the safe direction but not the server's
    /// answer — and it fails in a second, less obvious way: a cached copy of
    /// a *platform* type overlays the generated one, and since the generated
    /// set is flattened at build time, one successful refresh would otherwise
    /// replace resolved definitions with declared ones and quietly stop
    /// checking everything inherited.
    ///
    /// The order mirrors the server's exactly: seed the universal fields,
    /// then merge the chain from the root down, so a child overrides its
    /// parent and any type may override a universal. Idempotent, so running
    /// it over the already-flat platform set changes nothing.
    ///
    /// A cycle or a chain past ``maxResolutionDepth`` resolves to what was
    /// reached before the walk stopped rather than throwing. A malformed
    /// graph arriving from a server is not a reason to refuse every write on
    /// the device.
    public func resolved() -> MarfaTypeRegistry {
        MarfaTypeRegistry(
            definitions: definitions.mapValues { definition in
                var fields = Self.universalFields
                for ancestor in chain(from: definition) {
                    fields.merge(ancestor.fields) { _, nearer in nearer }
                }
                return MarfaTypeDefinition(
                    id: definition.id,
                    parent: definition.parent,
                    fields: fields,
                    titleField: definition.titleField,
                    bodyField: definition.bodyField,
                    schemaVersion: definition.schemaVersion
                )
            }
        )
    }

    /// The inheritance chain root-first, so a later entry overrides an
    /// earlier one.
    private func chain(from definition: MarfaTypeDefinition) -> [MarfaTypeDefinition] {
        var chain: [MarfaTypeDefinition] = [definition]
        var seen: Set<String> = [definition.id]
        var current = definition.parent
        while let parentId = current, seen.count < Self.maxResolutionDepth {
            guard let parent = definitions[parentId], seen.insert(parentId).inserted else { break }
            chain.insert(parent, at: 0)
            current = parent.parent
        }
        return chain
    }

    /// Fields every type carries whether it declares them or not, matching
    /// the server's own universal set. A type that declares one of these
    /// overrides it, which is why they are the seed rather than an overlay.
    static let universalFields: [String: MarfaFieldDefinition] = [
        "attachments": MarfaFieldDefinition(type: .array),
        "links": MarfaFieldDefinition(type: .array),
    ]

    /// How far a resolution walk goes before it gives up. The server carries
    /// the same backstop for the same reason: a registry assembled from a
    /// space's own types can hold a cycle.
    static let maxResolutionDepth = 32

    // MARK: - The graph

    /// Whether `typeId` is `ancestorId` or descends from it.
    ///
    /// This is what makes a query for a parent type return its subtypes. The
    /// walk is bounded by the number of types rather than trusted to
    /// terminate: a registry assembled from a server's custom types can carry
    /// a cycle, and a `while parent != nil` over one would hang the caller
    /// rather than answer it.
    public func isDescendant(_ typeId: String, of ancestorId: String) -> Bool {
        if typeId == ancestorId { return true }
        var seen: Set<String> = [typeId]
        var current = definitions[typeId]?.parent
        while let parent = current {
            if parent == ancestorId { return true }
            guard seen.insert(parent).inserted else { return false }
            current = definitions[parent]?.parent
        }
        return false
    }

    /// Every type that is `ancestorId` or descends from it, sorted.
    ///
    /// Returns the id itself even when the registry does not declare it, so a
    /// query for an unknown type narrows to that type rather than to nothing —
    /// matching what a local list did before a registry existed.
    public func typesAssignable(to ancestorId: String) -> [String] {
        let known = definitions.keys.filter { isDescendant($0, of: ancestorId) }
        return Set(known).union([ancestorId]).sorted()
    }

    /// The types a read filter naming `rootId` reaches that its *name* cannot.
    ///
    /// A subtree has two roots, not one. The dotted identifier is a namespace
    /// and the registry's `parent` is a declared lineage, and registration has
    /// never required a child's identifier to start with its parent's — so
    /// `user.annotated_note` may declare `core.note` as its parent and sit
    /// outside `core.note.*` entirely. The server resolves the union of both,
    /// and a device resolving names alone gives a short answer with no error.
    ///
    /// Only the ones the namespace walk misses are returned, because the
    /// caller already matches `rootId.` by prefix and every id this set
    /// carries has to travel into a fetch predicate as a captured collection.
    public func declaredDescendantsOutsideNamespace(of rootId: String) -> Set<String> {
        Self.declaredDescendantsOutsideNamespace(
            of: rootId,
            parents: definitions.compactMapValues(\.parent)
        )
    }

    /// The same walk over a bare `child: parent` map.
    ///
    /// A store answers this from two indexed columns rather than by decoding
    /// every cached type, and descent is the one question that needs nothing
    /// else. Kept beside the instance method so the two cannot drift.
    static func declaredDescendantsOutsideNamespace(
        of rootId: String,
        parents: [String: String]
    ) -> Set<String> {
        let namespace = rootId + "."
        var found: Set<String> = []
        for id in parents.keys where id != rootId && !id.hasPrefix(namespace) {
            // Bounded by the number of types rather than trusted to
            // terminate: a graph assembled from a server's custom types can
            // carry a cycle, and a `while parent != nil` over one would hang
            // the caller rather than answer.
            var seen: Set<String> = [id]
            var current = parents[id]
            while let parent = current {
                if parent == rootId { found.insert(id); break }
                guard seen.insert(parent).inserted else { break }
                current = parents[parent]
            }
        }
        return found
    }

    /// The fields offline search matches over, for a type.
    ///
    /// Falls back to `title` and `body` when the type names no hints, which is
    /// what the store searched before display hints reached the device.
    public func searchableFields(of typeId: String) -> [String] {
        guard let definition = definitions[typeId] else { return ["title", "body"] }
        let hinted = [definition.titleField, definition.bodyField].compactMap { $0 }
        return hinted.isEmpty ? ["title", "body"] : hinted
    }

    // MARK: - Validation

    /// Refuses a write the type forbids, by the rules the server applies by
    /// default. Throws ``TypeValidationError`` carrying every failure.
    public func validate(
        properties: [String: JSONValue],
        against typeId: String
    ) throws {
        guard let definition = definitions[typeId] else {
            throw TypeValidationError(
                typeId: typeId,
                failures: [.init(field: "_type", message: "Unknown type: \(typeId)")]
            )
        }

        var failures: [TypeValidationError.Failure] = []

        for (name, field) in definition.fields.sorted(by: { $0.key < $1.key }) {
            let value = properties[name]
            switch value {
            case nil, .null?:
                // An optional field treats an explicit null as unset, because
                // serializers routinely emit null for an absent value and
                // refusing it would make every such caller pre-prune. A
                // required field keeps the check, so a required field sent as
                // null still rejects — the same asymmetry the server has.
                if field.isRequired {
                    failures.append(.init(field: name, message: "Required field is missing"))
                }
            case .some(let present):
                if let failure = Self.check(present, against: field, named: name) {
                    failures.append(failure)
                }
            }
        }

        guard failures.isEmpty else {
            throw TypeValidationError(typeId: typeId, failures: failures)
        }
    }

    /// The server's own defaults, mirrored so a local resolution and a remote
    /// one agree about how much a field may hold. A custom type overriding
    /// either travels on the field definition.
    static let defaultMaxStringLength = 100_000
    static let defaultMaxArrayItems = 10_000

    private static func check(
        _ value: JSONValue,
        against field: MarfaFieldDefinition,
        named name: String
    ) -> TypeValidationError.Failure? {
        func wrongType(_ expected: String) -> TypeValidationError.Failure {
            .init(field: name, message: "Expected \(expected)")
        }

        switch field.type {
        case .string:
            guard case .string(let text) = value else { return wrongType("a string") }
            if let failure = boundedString(text, field: field, named: name) { return failure }
        case .number:
            // `int` and `double` are separate cases on the wire type, and both
            // are numbers to the server.
            guard value.intValue != nil || value.doubleValue != nil else {
                return wrongType("a number")
            }
        case .integer:
            if value.intValue != nil { break }
            // A whole double is an integer. JSON has one number type, so a
            // decoder that produced `.double(3.0)` for a value written as `3`
            // must not be refused where the server accepts it.
            guard let decimal = value.doubleValue, decimal.rounded() == decimal else {
                return wrongType("an integer")
            }
        case .boolean:
            guard case .bool = value else { return wrongType("a boolean") }
        case .url:
            guard case .string(let text) = value else { return wrongType("a URL string") }
            guard Self.isURL(text) else { return wrongType("a URL") }
        case .email:
            guard case .string(let text) = value else { return wrongType("an email string") }
            guard Self.isEmail(text) else { return wrongType("an email address") }
        case .datetime:
            guard case .string(let text) = value else { return wrongType("a datetime string") }
            // An instant with a mandatory offset, or a bare calendar date.
            // The offset is what makes a timed value an instant rather than a
            // wall-clock ambiguity; the bare date is the all-day shape.
            guard Self.isInstant(text) || Self.isCalendarDate(text) else {
                return wrongType("an ISO 8601 instant with an offset, or a date")
            }
        case .date:
            guard case .string(let text) = value else { return wrongType("a date string") }
            guard Self.isCalendarDate(text) else { return wrongType("a date as YYYY-MM-DD") }
        case .explicitEnum:
            guard case .string(let text) = value else { return wrongType("a string") }
            // An enum declaring no values is a plain string, which is what the
            // server falls back to rather than refusing everything.
            if let permitted = field.enumValues, !permitted.isEmpty {
                guard permitted.contains(text) else {
                    return .init(
                        field: name,
                        message: "Expected one of \(permitted.sorted().joined(separator: ", "))"
                    )
                }
            } else if let failure = boundedString(text, field: field, named: name) {
                // An enum declaring no values falls back to a bounded string on
                // the server too, bound and all.
                return failure
            }
        case .array:
            guard case .array(let elements) = value else { return wrongType("an array") }
            let maxItems = field.maxItems ?? defaultMaxArrayItems
            if elements.count > maxItems {
                return .init(field: name, message: "Expected at most \(maxItems) items")
            }
        case .object:
            guard value.dictionaryValue != nil else { return wrongType("an object") }
        }
        return nil
    }

    /// Length and NUL, the two bounds the server puts on every string.
    private static func boundedString(
        _ text: String,
        field: MarfaFieldDefinition,
        named name: String
    ) -> TypeValidationError.Failure? {
        let maxLength = field.maxLength ?? defaultMaxStringLength
        if text.count > maxLength {
            return .init(field: name, message: "Expected at most \(maxLength) characters")
        }
        if text.utf8.contains(0) {
            return .init(field: name, message: "A string may not contain a NUL byte")
        }
        return nil
    }

    // MARK: - Format checks

    /// Deliberately narrow, and narrow in the safe direction. Each of these
    /// accepts at least everything the server accepts, so a write the server
    /// would take is never refused here — a local check that is stricter than
    /// the server blocks work for a reason the person cannot act on, which is
    /// worse than the delay this whole registry exists to remove.
    private static func isURL(_ text: String) -> Bool {
        guard let components = URLComponents(string: text) else { return false }
        guard let scheme = components.scheme, !scheme.isEmpty else { return false }
        return components.host?.isEmpty == false || components.path.isEmpty == false
    }

    private static func isEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return parts[1].contains(".") && !text.contains(" ")
    }

    private static func isCalendarDate(_ text: String) -> Bool {
        guard text.count == 10 else { return false }
        let parts = text.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2
        else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    private static func isInstant(_ text: String) -> Bool {
        // A date, then a `T`, then a time, then an offset that is `Z` or
        // ±HH:MM. Checked structurally rather than by a formatter because
        // `ISO8601DateFormatter` accepts a naive local time, which is the one
        // shape the server refuses.
        //
        // No length floor. A minimum of twenty characters looked harmless and
        // singled out minute precision — `2026-09-04T23:00Z` is seventeen — so
        // it refused an instant the server accepts, on nine shipped fields.
        // The structural checks below are what decide; a length test in front
        // of them can only overrule them wrongly.
        guard text.contains("T") else { return false }
        let halves = text.split(separator: "T", maxSplits: 1)
        guard halves.count == 2, isCalendarDate(String(halves[0])) else { return false }
        let time = String(halves[1])
        if time.hasSuffix("Z") { return true }
        guard let signIndex = time.lastIndex(where: { $0 == "+" || $0 == "-" }) else { return false }
        let offset = time[time.index(after: signIndex)...]
        return offset.count == 5 && offset.contains(":")
    }
}
