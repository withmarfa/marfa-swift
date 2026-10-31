import Foundation
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct ItemDisplays {
    @Test func aNoteWithNoTitleIsNamedByTheFirstLineOfItsBodyAndThePreviewSkipsThatLine() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let shown = try await copy.items.displays(for: [
            ItemDisplayInput(
                type: "core.note", properties: ["body": "# Plan\n\nBuy **milk** and [[Eggs|eggs]].\n"])
        ])
        #expect(shown == [ItemDisplay(name: "Plan", preview: "Buy milk and eggs.")])
        await copy.close()
    }

    @Test func aTitleNamesTheNoteAndTheBodyKeepsItsFirstLine() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let shown = try await copy.items.displays(for: [
            ItemDisplayInput(type: "core.note", properties: ["title": "Groceries", "body": "- milk\n- eggs"])
        ])
        #expect(shown == [ItemDisplay(name: "Groceries", preview: "milk eggs")])
        await copy.close()
    }

    @Test func aSubtypeUsesTheDisplayHintsItInheritsAndEachItemKeepsItsPlace() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        try await copy.declareTypes([
            [
                "id": "app.log.entry", "fields": ["heading": ["type": "string"], "story": ["type": "string"]],
                "display_hints": ["title_field": "heading", "body_field": "story"],
            ],
            ["id": "app.log.daily", "parent": "app.log.entry"],
        ])
        let shown = try await copy.items.displays(for: [
            ItemDisplayInput(type: "app.log.daily", properties: ["heading": "Monday", "story": "It rained."]),
            ItemDisplayInput(type: "core.note", properties: ["title": "Second"]),
        ])
        #expect(shown == [ItemDisplay(name: "Monday", preview: "It rained."), ItemDisplay(name: "Second", preview: nil)])
        await copy.close()
    }

    @Test func anItemWithNothingToNameItHasNoNameAndNoPlaceholder() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let shown = try await copy.items.displays(for: [ItemDisplayInput(type: "core.note", properties: [:])])
        #expect(shown == [ItemDisplay(name: nil, preview: nil)])
        #expect(try await copy.items.displays(for: []).isEmpty)
        await copy.close()
    }

    @Test func itemsAnAppHoldsAreNamedInOrder() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let first = try #require(
            try await copy.items.create(Draft(type: "core.note", properties: ["title": "One", "body": "First body"]))
                .itemId)
        let second = try #require(
            try await copy.items.create(Draft(type: "core.note", properties: ["body": "Second\nbody"])).itemId)
        let items = try await copy.items.get([second, first]).rows
        #expect(
            try await copy.items.displays(of: items) == [
                ItemDisplay(name: "Second", preview: "body"), ItemDisplay(name: "One", preview: "First body"),
            ])
        await copy.close()
    }
}
