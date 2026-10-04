import Foundation
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct DeclaredTypes {
    static let definition =
        #"{"id":"app.readinglist.entry","fields":{"title":{"type":"string","required":true}}}"#

    @Test func declarationsPersistAndReplaceTheWholeSetOffline() async throws {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        #expect(try await copy.declaredTypes().isEmpty)
        try await copy.declareTypes([Self.definition])
        let held = try #require(try await copy.declaredTypes().first)
        let object = try #require(JSONSerialization.jsonObject(with: Data(held.utf8)) as? [String: Any])
        #expect(object["id"] as? String == "app.readinglist.entry")
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

    @Test func localCatalogChangesAreToldToObservers() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let heard = Heard(copy.changes())
        try await copy.declareTypes([Self.definition])
        try await eventually("the declared catalog was told") {
            heard.all.contains { $0.origin == .refreshed(.catalog) }
        }
        #expect(try await copy.catalog.itemType("app.readinglist.entry").id == "app.readinglist.entry")
        await copy.close()
    }

    @Test func anInvalidReplacementPreservesDeclarationsAndRefusesUnknownTypes() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        try await copy.declareTypes([Self.definition])
        let before = try await copy.declaredTypes()
        await #expect {
            try await copy.declareTypes(["{"])
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

    @Test(arguments: ["app.readinglist", "app.readinglist.entry.extra", "keys.entry"])
    func anInvalidRegistrationIdentifierPreservesTheDeclarationSet(id: String) async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        try await copy.declareTypes([Self.definition])
        let before = try await copy.declaredTypes()
        await #expect {
            try await copy.declareTypes([#"{"id":""# + id + #"","fields":{}}"#])
        } throws: { error in
            if case MarfaError.invalid = error { true } else { false }
        }
        #expect(try await copy.declaredTypes() == before)
        await copy.close()
    }
}
