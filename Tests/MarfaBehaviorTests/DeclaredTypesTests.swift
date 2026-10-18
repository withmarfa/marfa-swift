import Foundation
import Marfa
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DeclaredTypesOffline {
    static let definition: JSONObject = [
        "id": "app.readinglist.entry", "fields": ["title": ["type": "string", "required": true]],
    ]

    @Test(arguments: CopyKind.allCases)
    func aDeclarationIsHeldWithTheFieldsAndVersionARegistrationNeeds(kind: CopyKind) async throws {
        let copy = try await kind.open()
        #expect(try await copy.declaredTypes().isEmpty)
        try await copy.declareTypes([Self.definition, ["id": "app.readinglist.list", "label": "List"]])
        let held = try await copy.declaredTypes()
        #expect(
            held == [
                [
                    "id": "app.readinglist.entry", "fields": ["title": ["type": "string", "required": true]],
                    "version": 0,
                ],
                ["id": "app.readinglist.list", "label": "List", "fields": [:], "version": 0],
            ])
        let write = try await copy.items.create(
            Draft(type: "app.readinglist.entry", properties: ["title": "Read this"]))
        #expect(write.verdict == nil)
        #expect(write.body["tier"] == "library")
        let type = try await copy.catalog.itemType("app.readinglist.entry")
        #expect(type.fields.map(\.name) == ["title"])
        #expect(type.fields.first?.required == true)
        #expect(type.fields.first?.declaredBy == "app.readinglist.entry")
        try await copy.declareTypes([])
        #expect(try await copy.declaredTypes().isEmpty)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func localCatalogChangesAreToldToObservers(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let heard = Heard(copy.changes())
        try await copy.declareTypes([Self.definition])
        try await eventually("the declared catalog was told") {
            heard.all.contains { $0.origin == .refreshed(.catalog) }
        }
        #expect(try await copy.catalog.itemType("app.readinglist.entry").id == "app.readinglist.entry")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anInvalidReplacementPreservesDeclarationsAndRefusesUnknownTypes(kind: CopyKind) async throws {
        let copy = try await kind.open()
        try await copy.declareTypes([Self.definition])
        let before = try await copy.declaredTypes()
        await #expect {
            try await copy.declareTypes([["fields": [:]]])
        } throws: { error in
            if case MarfaError.invalid = error { true } else { false }
        }
        #expect(try await copy.declaredTypes() == before)
        await #expect {
            _ = try await copy.items.create(Draft(type: "app.other.entry", properties: ["title": "Unknown"]))
        } throws: { error in
            if case MarfaError.unknownType = error { true } else { false }
        }
        #expect(try await copy.queue.all().isEmpty)
        _ = try await copy.items.create(Draft(type: "app.readinglist.entry", properties: ["title": "Known"]))
        #expect(try await copy.queue.all().count == 1)
        await copy.close()
    }

    @Test(
        arguments: CopyKind.allCases,
        [
            "app.readinglist", "app.readinglist.entry.extra", "keys.entry", "app.Readinglist.entry",
            "app..entry", "app.reading.2entry", "core.note", "system.folder", "marfa.thing", "audit.log.entry",
        ])
    func anInvalidRegistrationIdentifierPreservesTheDeclarationSet(kind: CopyKind, id: String) async throws {
        let copy = try await kind.open()
        try await copy.declareTypes([Self.definition])
        let before = try await copy.declaredTypes()
        await #expect {
            try await copy.declareTypes([["id": .string(id), "fields": [:]]])
        } throws: { error in
            if case MarfaError.invalid = error { true } else { false }
        }
        #expect(try await copy.declaredTypes() == before)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases, ["app.a.b", "app.a-b.c_d", "user.recipe", "acme.memo", "x.y"])
    func anIdentifierInTheGrammarIsDeclared(kind: CopyKind, id: String) async throws {
        let copy = try await kind.open()
        try await copy.declareTypes([["id": .string(id)]])
        #expect(try await copy.declaredTypes().map { $0["id"] } == [.string(id)])
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aDeclaredTypeInheritsItsParentsFieldsAndHints(kind: CopyKind) async throws {
        let copy = try await kind.open()
        try await copy.declareTypes([
            ["id": "app.notes.memo", "parent": "core.note", "display_hints": ["title_field": "heading"]],
            ["id": "app.notes.plain", "parent": "app.notes.memo", "fields": ["heading": ["type": "string"]]],
        ])
        let memo = try await copy.catalog.itemType("app.notes.memo")
        #expect(memo.parent == "core.note")
        #expect(memo.titleField == "heading")
        #expect(memo.fields.map(\.name).contains("body"))
        #expect(memo.fields.first { $0.name == "body" }?.declaredBy == "core.note")
        let plain = try await copy.catalog.itemType("app.notes.plain")
        #expect(plain.titleField == "heading")
        #expect(plain.fields.first { $0.name == "heading" }?.declaredBy == "app.notes.plain")
        #expect(plain.fields.first { $0.name == "body" }?.required == true)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aDeclarationNamingAnUnknownParentOrABadFieldIsRefused(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let refused: [JSONObject] = [
            ["id": "app.a.b", "parent": "app.nowhere.type"],
            ["id": "app.a.b", "fields": "no"],
            ["id": "app.a.b", "fields": ["x": ["type": "blob"]]],
            ["id": "app.a.b", "fields": ["x": ["required": true]]],
        ]
        for definition in refused {
            await #expect {
                try await copy.declareTypes([definition])
            } throws: { error in
                if case MarfaError.invalid = error { true } else { false }
            }
        }
        #expect(try await copy.declaredTypes().isEmpty)
        await copy.close()
    }
}
