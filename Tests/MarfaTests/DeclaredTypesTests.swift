import Foundation
import Testing

@testable import Marfa

/// The declarations that need a store reopened.
///
/// The rest are held to the fake copy as well, in `DeclaredTypesOffline`.
@Suite(.timeLimit(.minutes(1)))
struct DeclaredTypes {
    static let definition: JSONObject = [
        "id": "app.readinglist.entry", "fields": ["title": ["type": "string", "required": true]],
    ]

    @Test func declarationsPersistAndReplaceTheWholeSetOffline() async throws {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        #expect(try await copy.declaredTypes().isEmpty)
        try await copy.declareTypes([Self.definition])
        let held = try #require(try await copy.declaredTypes().first)
        #expect(held["id"] == "app.readinglist.entry")
        let write = try await copy.items.create(
            Draft(type: "app.readinglist.entry", properties: ["title": "Read this"]))
        #expect(write.verdict == nil)
        #expect(write.body["tier"] == "library")
        #expect(try await copy.catalog.itemType("app.readinglist.entry").fields.contains { $0.name == "title" })
        await copy.close()
        let reopened = try await WorkingCopy.open(store: store)
        #expect(try await reopened.declaredTypes() == [held])
        try await reopened.declareTypes([])
        #expect(try await reopened.declaredTypes().isEmpty)
        #expect(try await reopened.queue.all().contains { $0.id == write.id })
        await reopened.close()
    }
}
