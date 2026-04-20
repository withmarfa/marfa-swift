import Testing
@testable import MymeCodegenCore

@Suite struct SchemaResolverTests {

    // MARK: - Fixtures

    let parent = CodegenTypeSchema(
        id: "core.note",
        version: 1,
        fields: [
            "body": CodegenFieldDefinition(type: "string", description: "The note text"),
            "title": CodegenFieldDefinition(type: "string", description: "Heading or title"),
        ],
        required: ["body"],
        displayHints: CodegenDisplayHints(titleField: "title", bodyField: "body")
    )

    let child = CodegenTypeSchema(
        id: "myapp.booking",
        parent: "core.note",
        version: 2,
        fields: [
            "start_at": CodegenFieldDefinition(type: "string", format: "datetime"),
            "party_size": CodegenFieldDefinition(type: "integer"),
        ],
        required: ["start_at"]
    )

    // MARK: - Single level

    @Test func flatSchemaResolvesToItsOwnFields() throws {
        let resolved = try SchemaResolver.resolve(
            schema: parent,
            registry: ["core.note": parent]
        )
        #expect(resolved.inheritedFieldGroups.isEmpty)
        #expect(resolved.ownFields.map(\.key) == ["body", "title"])
        #expect(resolved.requiredFields == ["body"])
    }

    @Test func childMergesParentFieldsIntoInheritedGroup() throws {
        let resolved = try SchemaResolver.resolve(
            schema: child,
            registry: ["core.note": parent, "myapp.booking": child]
        )
        #expect(resolved.ownFields.map(\.key) == ["start_at", "party_size"])
        #expect(resolved.inheritedFieldGroups.count == 1)
        #expect(resolved.inheritedFieldGroups[0].parentID == "core.note")
        #expect(resolved.inheritedFieldGroups[0].fields.map(\.key) == ["body", "title"])
    }

    @Test func childRequiredUnionsWithParent() throws {
        let resolved = try SchemaResolver.resolve(
            schema: child,
            registry: ["core.note": parent, "myapp.booking": child]
        )
        #expect(resolved.requiredFields == ["start_at", "body"])
    }

    @Test func nearestAncestorDisplayHintsWin() throws {
        let resolved = try SchemaResolver.resolve(
            schema: child,
            registry: ["core.note": parent, "myapp.booking": child]
        )
        #expect(resolved.displayHints?.titleField == "title")
        #expect(resolved.displayHints?.bodyField == "body")
    }

    @Test func ownDisplayHintsTrumpParent() throws {
        let override = CodegenTypeSchema(
            id: "myapp.booking",
            parent: "core.note",
            version: 1,
            fields: ["party_size": CodegenFieldDefinition(type: "integer")],
            required: [],
            displayHints: CodegenDisplayHints(titleField: "party_size", bodyField: nil)
        )
        let resolved = try SchemaResolver.resolve(
            schema: override,
            registry: ["core.note": parent, "myapp.booking": override]
        )
        #expect(resolved.displayHints?.titleField == "party_size")
    }

    // MARK: - Error paths

    @Test func missingParentThrows() {
        let orphan = CodegenTypeSchema(
            id: "myapp.orphan",
            parent: "unknown.parent",
            version: 1,
            fields: ["x": CodegenFieldDefinition(type: "string")]
        )
        #expect {
            _ = try SchemaResolver.resolve(schema: orphan, registry: ["myapp.orphan": orphan])
        } throws: { error in
            if case SchemaResolverError.missingParent = error { return true }
            return false
        }
    }

    @Test func circularInheritanceThrows() {
        let a = CodegenTypeSchema(id: "a", parent: "b", version: 1, fields: [:])
        let b = CodegenTypeSchema(id: "b", parent: "a", version: 1, fields: [:])
        #expect {
            _ = try SchemaResolver.resolve(schema: a, registry: ["a": a, "b": b])
        } throws: { error in
            if case SchemaResolverError.circularInheritance = error { return true }
            return false
        }
    }

    @Test func fieldRedeclarationThrows() {
        let redeclarer = CodegenTypeSchema(
            id: "myapp.sub_note",
            parent: "core.note",
            version: 1,
            fields: [
                "body": CodegenFieldDefinition(type: "string", description: "override"),
            ],
            required: []
        )
        #expect {
            _ = try SchemaResolver.resolve(
                schema: redeclarer,
                registry: ["core.note": parent, "myapp.sub_note": redeclarer]
            )
        } throws: { error in
            if case SchemaResolverError.fieldRedeclared(_, _, let field) = error {
                return field == "body"
            }
            return false
        }
    }

    // MARK: - Multi-level inheritance

    @Test func twoLevelChainMergesBothAncestors() throws {
        let grand = CodegenTypeSchema(
            id: "core.media",
            version: 1,
            fields: ["title": CodegenFieldDefinition(type: "string")],
            required: ["title"]
        )
        let mid = CodegenTypeSchema(
            id: "core.media.book",
            parent: "core.media",
            version: 1,
            fields: ["isbn": CodegenFieldDefinition(type: "string")],
            required: []
        )
        let leaf = CodegenTypeSchema(
            id: "myapp.signed_book",
            parent: "core.media.book",
            version: 1,
            fields: ["signed_by": CodegenFieldDefinition(type: "string")],
            required: ["signed_by"]
        )
        let resolved = try SchemaResolver.resolve(
            schema: leaf,
            registry: ["core.media": grand, "core.media.book": mid, "myapp.signed_book": leaf]
        )
        #expect(resolved.ownFields.map(\.key) == ["signed_by"])
        #expect(resolved.inheritedFieldGroups.count == 2)
        #expect(resolved.inheritedFieldGroups[0].parentID == "core.media.book")
        #expect(resolved.inheritedFieldGroups[1].parentID == "core.media")
        #expect(resolved.requiredFields == ["signed_by", "title"])
    }
}
