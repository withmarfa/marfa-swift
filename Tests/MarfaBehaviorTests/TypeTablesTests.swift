#if DEBUG
import Foundation
import Marfa
import MarfaTesting
import Testing

/// Which item types hold a table, read from the catalog alone.
@Suite(.timeLimit(.minutes(1)))
struct TypeTablesOffline {
    static let chat: JSONObject = ["id": "app.readinglist.chat", "parent": "core.conversation"]

    @Test(arguments: CopyKind.allCases)
    func aTypeThatDeclaresATableNamesIt(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let type = try await copy.catalog.itemType("core.conversation")
        #expect(type.holdsTable)
        #expect(type.tableNames == ["messages"])
        #expect(type.tables.members.map(\.key) == ["messages"])
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aSubtypeHoldsTheTablesItInherits(kind: CopyKind) async throws {
        let copy = try await kind.open(declaring: [Self.chat])
        let parent = try await copy.catalog.itemType("core.conversation")
        let child = try await copy.catalog.itemType("app.readinglist.chat")
        #expect(child.holdsTable)
        #expect(child.tables == parent.tables)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aTypeWithNoTableHoldsNone(kind: CopyKind) async throws {
        let copy = try await kind.open(declaring: [["id": "app.readinglist.entry"]])
        for id in ["core.note", "app.readinglist.entry"] {
            let type = try await copy.catalog.itemType(id)
            #expect(!type.holdsTable)
            #expect(type.tableNames.isEmpty)
            #expect(type.tables.members.isEmpty)
        }
        let withTables = try await copy.catalog.itemTypes().filter(\.holdsTable).map(\.id)
        #expect(withTables.contains("core.conversation"))
        #expect(!withTables.contains("core.note"))
        await copy.close()
    }

    @Test func theFakeThrowsUnsupportedForADeclarationThatDeclaresATable() async throws {
        let copy = try await CopyKind.makeFake().copy
        await #expect {
            try await copy.declareTypes([
                ["id": "app.readinglist.log", "tables": ["steps": ["columns": ["note": ["type": "string"]]]]]
            ])
        } throws: { error in
            (error as? FakeCopyError) == .unsupported(call: "declareTypes with a table in app.readinglist.log")
        }
        #expect(try await copy.declaredTypes().isEmpty)
        await copy.close()
    }
}
#endif
