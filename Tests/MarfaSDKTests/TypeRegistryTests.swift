import Testing
import Foundation
@testable import MarfaSDK

/// The type graph on the device: what it knows, how it answers a question
/// about descent, and what it refuses.
///
/// The generated registry itself is guarded by the codegen freshness job
/// rather than by a test here — a test asserting the generated content would
/// be a second reading of the same JSON, and two readings that agree prove
/// only that they agree. What these pin is the behavior built on top of it.
@Suite("The platform type registry", .timeLimit(.minutes(1)))
struct TypeRegistryTests {

    private var registry: MarfaTypeRegistry { .platform }

    // MARK: - What ships

    @Test("the registry carries core and system types, with inherited fields flattened")
    func carriesBothNamespaces() {
        #expect(registry.definition(for: "core.note") != nil)
        #expect(registry.definition(for: "system.connection") != nil, "system types are not domain models but a device still holds their rows")

        let person = try? #require(registry.definition(for: "core.entity.person"))
        #expect(person?.parent == "core.entity")
        // A field the parent declares and the child does not.
        #expect(person?.fields["name"] != nil || person?.fields["description"] != nil,
                "the parent chain was not flattened into the child")
    }

    // MARK: - Descent

    @Test("a subtype is assignable to its ancestor, and an unrelated type is not")
    func descent() {
        #expect(registry.isDescendant("core.entity.person", of: "core.entity"))
        #expect(registry.isDescendant("core.entity", of: "core.entity"), "a type is assignable to itself")
        #expect(registry.isDescendant("core.note", of: "core.entity") == false)
        // The discriminator: descent runs one way only.
        #expect(registry.isDescendant("core.entity", of: "core.entity.person") == false)
    }

    @Test("a query for a parent type names its descendants")
    func assignableSet() {
        let assignable = registry.typesAssignable(to: "core.entity")
        #expect(assignable.contains("core.entity"))
        #expect(assignable.contains("core.entity.person"))
        #expect(assignable.contains("core.note") == false)
    }

    @Test("an unknown type narrows to itself rather than to nothing")
    func unknownTypeNarrowsToItself() {
        #expect(registry.typesAssignable(to: "myapp.invoice") == ["myapp.invoice"])
    }

    /// A registry assembled from a server's custom types can carry a cycle,
    /// and a walk that trusted the chain to terminate would hang the caller
    /// rather than answer. Constructed rather than waited for, because no
    /// platform type is cyclic and the failure is a hang rather than a wrong
    /// answer — the one shape a test cannot observe by accident.
    @Test("a cyclic parent chain terminates instead of hanging")
    func cycleTerminates() {
        let cyclic = MarfaTypeRegistry(definitions: [
            "a": MarfaTypeDefinition(id: "a", parent: "b"),
            "b": MarfaTypeDefinition(id: "b", parent: "a"),
        ])
        #expect(cyclic.isDescendant("a", of: "unrelated") == false)
        #expect(cyclic.isDescendant("a", of: "b"))
    }

    // MARK: - Validation

    @Test("a missing required field is refused")
    func missingRequired() {
        #expect(throws: TypeValidationError.self) {
            try registry.validate(properties: ["title": .string("no body")], against: "core.note")
        }
    }

    @Test("a required field present is accepted, which is the discriminator")
    func requiredPresent() throws {
        try registry.validate(properties: ["body": .string("here")], against: "core.note")
    }

    @Test("an unknown type is refused")
    func unknownType() {
        #expect(throws: TypeValidationError.self) {
            try registry.validate(properties: [:], against: "myapp.invoice")
        }
    }

    /// The server validates with a loose object unless a space turns on strict
    /// enforcement, so an undeclared property passes. Refusing it here would
    /// block a write the server accepts, which is worse than the delay this
    /// registry removes.
    @Test("an undeclared property passes, because the server passes it")
    func undeclaredPropertyPasses() throws {
        try registry.validate(
            properties: ["body": .string("here"), "not_a_declared_field": .string("x")],
            against: "core.note"
        )
    }

    @Test("a declared field holding the wrong type is refused")
    func wrongType() throws {
        let error = try #require(throws: TypeValidationError.self) {
            try registry.validate(
                properties: ["body": .int(3)],
                against: "core.note"
            )
        }
        #expect(error.failures.contains { $0.field == "body" })
    }

    /// An optional field treats an explicit null as unset, because serializers
    /// routinely emit null for an absent value. A required field keeps the
    /// check — the same asymmetry the server has.
    @Test("null clears an optional field and still refuses a required one")
    func nullAsymmetry() throws {
        try registry.validate(
            properties: ["body": .string("here"), "title": .null],
            against: "core.note"
        )

        #expect(throws: TypeValidationError.self) {
            try registry.validate(properties: ["body": .null], against: "core.note")
        }
    }

    @Test("every failure is reported, not just the first")
    func reportsEveryFailure() throws {
        let registry = MarfaTypeRegistry(definitions: [
            "t": MarfaTypeDefinition(id: "t", fields: [
                "a": .init(type: .string, isRequired: true),
                "b": .init(type: .integer, isRequired: true),
            ]),
        ])
        let error = try #require(throws: TypeValidationError.self) {
            try registry.validate(properties: [:], against: "t")
        }
        #expect(error.failures.count == 2, "stopping early would disagree with the server, which returns them all")
    }

    @Test("an enum accepts a declared value and refuses one it does not declare")
    func enumValues() throws {
        let registry = MarfaTypeRegistry(definitions: [
            "t": MarfaTypeDefinition(id: "t", fields: [
                "color": .init(type: .explicitEnum, enumValues: ["red", "blue"]),
            ]),
        ])
        try registry.validate(properties: ["color": .string("red")], against: "t")
        #expect(throws: TypeValidationError.self) {
            try registry.validate(properties: ["color": .string("green")], against: "t")
        }
    }

    /// A whole double is an integer. JSON has one number type, so a decoder
    /// that produced `.double(3.0)` for a value written as `3` must not be
    /// refused where the server accepts it.
    @Test("an integer field accepts a whole double and refuses a fractional one")
    func integerAcceptsWholeDouble() throws {
        let registry = MarfaTypeRegistry(definitions: [
            "t": MarfaTypeDefinition(id: "t", fields: ["n": .init(type: .integer)]),
        ])
        try registry.validate(properties: ["n": .int(3)], against: "t")
        try registry.validate(properties: ["n": .double(3.0)], against: "t")
        #expect(throws: TypeValidationError.self) {
            try registry.validate(properties: ["n": .double(3.5)], against: "t")
        }
    }

    @Test("an array over its declared bound is refused")
    func arrayBound() throws {
        let registry = MarfaTypeRegistry(definitions: [
            "t": MarfaTypeDefinition(id: "t", fields: ["xs": .init(type: .array, maxItems: 2)]),
        ])
        try registry.validate(properties: ["xs": .array([.int(1), .int(2)])], against: "t")
        #expect(throws: TypeValidationError.self) {
            try registry.validate(properties: ["xs": .array([.int(1), .int(2), .int(3)])], against: "t")
        }
    }

    /// The format checks are deliberately narrow and narrow in the safe
    /// direction: each accepts at least everything the server accepts, so a
    /// write the server would take is never refused here.
    @Test("a datetime needs an offset, and a bare date is the all-day shape")
    func datetimeShapes() throws {
        let registry = MarfaTypeRegistry(definitions: [
            "t": MarfaTypeDefinition(id: "t", fields: ["at": .init(type: .datetime)]),
        ])
        try registry.validate(properties: ["at": .string("2026-09-04T10:00:00Z")], against: "t")
        try registry.validate(properties: ["at": .string("2026-09-04T10:00:00+01:00")], against: "t")
        try registry.validate(properties: ["at": .string("2026-09-04")], against: "t")
        // A naive local time is neither an instant nor an all-day date, and
        // the server refuses it so it cannot surface later as a parse error.
        #expect(throws: TypeValidationError.self) {
            try registry.validate(properties: ["at": .string("2026-09-04T10:00:00")], against: "t")
        }
    }

    // MARK: - The bounds and formats the server applies to every field

    /// A declared `format` collapses into a field type on the server, so
    /// `{"type": "string", "format": "url"}` is checked as a URL. Reading
    /// `type` alone dropped every one of them — sixty fields, including every
    /// format on a `core.*` type, which is the half apps write. Asserted
    /// against a *real* platform type rather than a constructed one, because
    /// the defect was in the generator and a synthetic registry cannot see it.
    @Test("a declared format is checked on a real platform type")
    func formatCollapsesOnAPlatformType() throws {
        #expect(throws: TypeValidationError.self) {
            try registry.validate(
                properties: ["source_url": .string("definitely not a url")],
                against: "core.bookmark"
            )
        }
        // The discriminator: a real URL passes, so the red above is the format
        // check rather than the field being refused outright.
        try registry.validate(
            properties: ["source_url": .string("https://example.com/a")],
            against: "core.bookmark"
        )
    }

    /// A minute-precision instant is seventeen characters, and a length floor
    /// of twenty refused it while the server accepts it — the one direction
    /// that blocks work nobody can act on. Nine shipped fields were affected.
    @Test("an instant without seconds is accepted")
    func minutePrecisionInstant() throws {
        let registry = MarfaTypeRegistry(definitions: [
            "t": MarfaTypeDefinition(id: "t", fields: ["at": .init(type: .datetime)]),
        ])
        try registry.validate(properties: ["at": .string("2026-09-04T23:00Z")], against: "t")
        try registry.validate(properties: ["at": .string("2026-09-04T23:00:00Z")], against: "t")
        // Still refused, because the offset is what makes it an instant.
        #expect(throws: TypeValidationError.self) {
            try registry.validate(properties: ["at": .string("2026-09-04T23:00")], against: "t")
        }
    }

    /// The server bounds every string and refuses a NUL byte. A 200KB string
    /// passing locally, queueing, and being refused hours later is exactly the
    /// failure this registry exists to remove.
    @Test("a string over the bound, or carrying a NUL, is refused")
    func stringBounds() throws {
        let registry = MarfaTypeRegistry(definitions: [
            "t": MarfaTypeDefinition(id: "t", fields: [
                "free": .init(type: .string),
                "short": .init(type: .string, maxLength: 4),
            ]),
        ])
        try registry.validate(properties: ["free": .string("ordinary")], against: "t")

        #expect(throws: TypeValidationError.self) {
            try registry.validate(
                properties: ["free": .string(String(repeating: "x", count: 100_001))],
                against: "t"
            )
        }
        #expect(throws: TypeValidationError.self) {
            try registry.validate(properties: ["free": .string("a\u{0000}b")], against: "t")
        }
        // A type's own bound overrides the default in both directions.
        try registry.validate(properties: ["short": .string("abcd")], against: "t")
        #expect(throws: TypeValidationError.self) {
            try registry.validate(properties: ["short": .string("abcde")], against: "t")
        }
    }

    /// The server seeds every resolved field set with these two, so a type
    /// declaring neither still refuses a string where an array belongs.
    @Test("every type carries the universal fields")
    func universalFields() throws {
        #expect(throws: TypeValidationError.self) {
            try registry.validate(
                properties: ["body": .string("here"), "attachments": .string("not an array")],
                against: "core.note"
            )
        }
        try registry.validate(
            properties: ["body": .string("here"), "attachments": .array([]), "links": .array([])],
            against: "core.note"
        )
    }

    /// An array has a default bound too, and it is the server's.
    @Test("an array over the default bound is refused")
    func arrayDefaultBound() throws {
        let registry = MarfaTypeRegistry(definitions: [
            "t": MarfaTypeDefinition(id: "t", fields: ["xs": .init(type: .array)]),
        ])
        try registry.validate(
            properties: ["xs": .array(Array(repeating: .int(1), count: 10_000))],
            against: "t"
        )
        #expect(throws: TypeValidationError.self) {
            try registry.validate(
                properties: ["xs": .array(Array(repeating: .int(1), count: 10_001))],
                against: "t"
            )
        }
    }

    /// Mirrored constants drift silently, so they are pinned rather than
    /// trusted — the same reason the bulk-action caps are.
    @Test("the bounds mirror the server's constants")
    func boundsMirrorTheServer() {
        #expect(MarfaTypeRegistry.defaultMaxStringLength == 100_000)
        #expect(MarfaTypeRegistry.defaultMaxArrayItems == 10_000)
    }

    // MARK: - Search

    @Test("searchable fields come from the display hints, with a fallback")
    func searchableFields() {
        #expect(registry.searchableFields(of: "core.note") == ["title", "body"])
        // A type the registry does not know still searches somewhere sensible.
        #expect(registry.searchableFields(of: "myapp.invoice") == ["title", "body"])
    }

    /// The divergence rule 15 names: a type keying its text somewhere other
    /// than `title` and `body` was unfindable offline because the store
    /// searched those two columns regardless of what the type declared.
    @Test("a type whose text lives elsewhere names its own fields")
    func hintsAwayFromTheDefaults() {
        let registry = MarfaTypeRegistry(definitions: [
            "t": MarfaTypeDefinition(id: "t", titleField: "headline", bodyField: "abstract"),
        ])
        #expect(registry.searchableFields(of: "t") == ["headline", "abstract"])
    }

    // MARK: - Overlay

    @Test("a space's custom types join the platform set, and win a collision")
    func overlayWins() {
        let merged = registry.merging([
            "myapp.invoice": MarfaTypeDefinition(id: "myapp.invoice", parent: "core.note"),
            "core.note": MarfaTypeDefinition(id: "core.note", fields: ["custom": .init(type: .string)]),
        ])
        #expect(merged.definition(for: "myapp.invoice") != nil)
        #expect(merged.definition(for: "core.note")?.fields.keys.contains("custom") == true,
                "a space's copy is the one its rows were written against")
        #expect(merged.isDescendant("myapp.invoice", of: "core.note"))
    }
}
