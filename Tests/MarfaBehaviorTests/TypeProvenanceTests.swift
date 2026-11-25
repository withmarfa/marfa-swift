#if DEBUG
import Marfa
import MarfaTesting
import Testing

@Suite struct TypeProvenance {
    @Test(arguments: CopyKind.allCases)
    func declaredTypesHaveRegisteredOrigin(kind: CopyKind) async throws {
        let id = "app.readinglist.story"
        let copy = try await kind.open(declaring: [["id": .string(id)]])
        let type = try await copy.catalog.itemType(id)
        #expect(type.origin == .registered)
        #expect(type.plugin == nil)
        #expect(try await copy.catalog.itemTypes().first { $0.id == id } == type)
        await copy.close()
    }

    @Test func theFakeAnswersTheOriginAndPluginItWasGiven() async throws {
        let plugin = TypePlugin(name: "reading", version: "1.2.3")
        let types = [
            ItemType(id: "core.note", origin: .platform),
            ItemType(id: "reading.story", origin: .plugin, plugin: plugin),
            ItemType(id: "user.unknown"),
        ]
        let copy = WorkingCopy.fake(itemTypes: types).copy
        #expect(try await copy.catalog.itemTypes() == types)
        #expect(try await copy.catalog.itemType("reading.story").plugin == plugin)
        await copy.close()
    }

    @Test func theFakeRefusesADeclarationThatSetsItsOwnProvenance() async throws {
        let copy = WorkingCopy.fake().copy
        await #expect(throws: FakeCopyError.unsupported(call: "declareTypes with provenance in app.readinglist.story"))
        {
            try await copy.declareTypes([["id": "app.readinglist.story", "provenance": ["origin": "platform"]]])
        }
        #expect(try await copy.declaredTypes().isEmpty)
        await copy.close()
    }
}
#endif
