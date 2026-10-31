#if DEBUG
import Foundation
import Marfa
import Testing

/// The label of each field and the plural of each type, which the copy always answers.
@Suite(.timeLimit(.minutes(1)))
struct FieldLabelsOffline {
    static let types: [JSONObject] = [
        [
            "id": "app.sheet.base", "label": "Base", "plural": "Bases",
            "fields": ["due": ["type": "date", "label": "Due"], "phone_numbers": ["type": "string"]],
        ],
        [
            "id": "app.sheet.child", "label": "Entry", "parent": "app.sheet.base",
            "fields": ["due": ["type": "date"], "cost": ["type": "number", "label": "Price"]],
        ],
    ]

    @Test(arguments: CopyKind.allCases)
    func aFieldTakesItsOwnLabelTheNearestInheritedOneOrOneMadeFromItsName(kind: CopyKind) async throws {
        let copy = try await kind.open(declaring: Self.types)
        let child = try await copy.catalog.itemType("app.sheet.child")
        func label(_ name: String) throws -> String { try #require(child.fields.first { $0.name == name }).label }
        #expect(try label("cost") == "Price")
        #expect(try label("due") == "Due")
        #expect(try label("phone_numbers") == "Phone Numbers")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aTypeTakesItsOwnPluralOrOneMadeFromItsLabel(kind: CopyKind) async throws {
        let copy = try await kind.open(declaring: Self.types)
        #expect(try await copy.catalog.itemType("app.sheet.base").plural == "Bases")
        #expect(try await copy.catalog.itemType("app.sheet.child").plural == "Entries")
        await copy.close()
    }
}
#endif
