#if DEBUG
import Foundation
import Marfa
import Testing

/// A list and a search narrowed by sets of types and states, on both copies.
@Suite(.timeLimit(.minutes(1)))
struct FilterSets {
    struct Held {
        var note: String
        var task: String
        var archivedNote: String
        var binnedTask: String
    }

    static func hold(in copy: WorkingCopy) async throws -> Held {
        func create(_ type: String, _ title: String, state: ItemState = .active) async throws -> String {
            try #require(
                try await copy.items.create(
                    Draft(type: type, properties: ["title": .string(title), "body": "marmalade"], state: state)
                ).itemId)
        }
        return Held(
            note: try await create("core.note", "a note"),
            task: try await create("core.task", "a task"),
            archivedNote: try await create("core.note", "an archived note", state: .archived),
            binnedTask: try await create("core.task", "a binned task", state: .trashed))
    }

    static func validation(_ code: String) -> (any Error) -> Bool {
        { error in
            if case .validation(let given, _)? = error as? MarfaError { given == code } else { false }
        }
    }

    @Test(arguments: CopyKind.allCases)
    func aListTakesSeveralTypesAndSeveralStates(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let held = try await Self.hold(in: copy)
        func ids(_ filters: ListFilters) async throws -> Set<String> {
            Set(try await copy.items.list(filters).map(\.id))
        }

        #expect(try await ids(ListFilters(types: ["core.note", "core.task"])) == [held.note, held.task])
        #expect(try await ids(ListFilters(types: ["core.note"])) == [held.note])
        #expect(try await ids(ListFilters(states: [.active, .archived])) == [held.note, held.task, held.archivedNote])
        #expect(try await ids(ListFilters(states: [.trashed])) == [held.binnedTask])
        #expect(
            try await ids(ListFilters(types: ["core.note", "core.task"], states: [.archived, .trashed]))
                == [held.archivedNote, held.binnedTask])
        #expect(try await ids(ListFilters(types: ["core.task"], states: [.archived])) == [])
        #expect(try await ids(ListFilters(types: ["core.note", "core.task"], limit: 1)).count == 1)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aSearchTakesSeveralTypesAndStatesButNeverMatchesTheBin(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let held = try await Self.hold(in: copy)
        func ids(_ filters: SearchFilters) async throws -> Set<String> {
            Set(try await copy.search("marmalade", filters: filters).map(\.item.id))
        }

        #expect(try await ids(SearchFilters(types: ["core.note", "core.task"])) == [held.note, held.task])
        #expect(
            try await ids(SearchFilters(states: [.active, .archived])) == [held.note, held.task, held.archivedNote])
        #expect(
            try await ids(SearchFilters(types: ["core.note", "core.task"], states: [.archived, .active]))
                == [held.note, held.task, held.archivedNote])
        #expect(try await ids(SearchFilters(types: ["core.task"], states: [.archived])) == [])
        // The bin is not searchable, even when the filter names it.
        #expect(try await ids(SearchFilters(states: [.trashed])) == [])
        #expect(try await ids(SearchFilters(states: [.active, .trashed])) == [held.note, held.task])
        #expect(try await ids(SearchFilters(allStates: true)) == [held.note, held.task, held.archivedNote])
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aSetTheCoreRefusesIsRefusedAsTheCoreDoes(kind: CopyKind) async throws {
        let copy = try await kind.open()
        _ = try await Self.hold(in: copy)
        let eleven = Set((0..<11).map { "app.t\($0).*" })
        let unknown: (any Error) -> Bool = { error in
            if case .unknownType? = error as? MarfaError { true } else { false }
        }

        await #expect(
            performing: { _ = try await copy.items.list(ListFilters(types: [])) },
            throws: Self.validation("validation_error"))
        await #expect(
            performing: { _ = try await copy.items.list(ListFilters(types: eleven)) },
            throws: Self.validation("validation_error"))
        await #expect(
            performing: { _ = try await copy.items.list(ListFilters(types: ["core.note", "app.nope.type"])) },
            throws: unknown)
        await #expect(
            performing: { _ = try await copy.items.list(ListFilters(states: [])) },
            throws: Self.validation("validation_error"))
        await #expect(
            performing: { _ = try await copy.items.list(ListFilters(states: [.archived], allStates: true)) },
            throws: Self.validation("validation_error"))

        await #expect(
            performing: { _ = try await copy.search("marmalade", filters: SearchFilters(types: [])) },
            throws: Self.validation("validation_error"))
        await #expect(
            performing: { _ = try await copy.search("marmalade", filters: SearchFilters(types: eleven)) },
            throws: Self.validation("validation_error"))
        await #expect(
            performing: {
                _ = try await copy.search("marmalade", filters: SearchFilters(types: ["core.note", "app.nope.type"]))
            }, throws: unknown)
        await #expect(
            performing: { _ = try await copy.search("marmalade", filters: SearchFilters(states: [])) },
            throws: Self.validation("validation_error"))
        await #expect(
            performing: {
                _ = try await copy.search("marmalade", filters: SearchFilters(states: [.active], allStates: true))
            },
            throws: Self.validation("validation_error"))
        await copy.close()
    }
}
#endif
