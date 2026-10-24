import Foundation
import MarfaAPI
import Testing

@testable import Marfa

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(1)))
    struct LiveClient {
        @Test func anAppRegistersChecksReplacesAndDeletesItsTypes() async throws {
            let api = Client(try #require(Live.server))
            let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let id = "app.swift\(suffix).entry"
            let title = Components.Schemas.FieldDefinition(_type: .string, required: true)
            let definition = Components.Schemas.TypeDefinitionInput(
                fields: .init(additionalProperties: ["title": title]), id: id)

            let checked = try await api.check(itemType: definition)
            #expect(checked._type.id == id)
            await #expect(throws: MarfaError.self) { try await api.replace(itemType: id, with: .init(fields: .init())) }

            let registered = try await api.register(itemType: definition)
            #expect(registered.value1.id == id)
            #expect(registered.value1.fields.additionalProperties.keys.sorted() == ["title"])

            let notes = Components.Schemas.FieldDefinition(_type: .string)
            let replaced = try await api.replace(
                itemType: id, with: .init(fields: .init(additionalProperties: ["title": title, "notes": notes])))
            #expect(replaced.value1.fields.additionalProperties.keys.sorted() == ["notes", "title"])

            try await api.delete(itemType: id)
            let gone = await #expect(throws: MarfaError.self) { try await api.delete(itemType: id) }
            #expect(gone?.code() == "not_found", "\(String(describing: gone))")

            let edge = "app.swift\(suffix).follows"
            let made = try await api.register(edgeType: .init(id: edge, cardinality: .manyToMany))
            #expect(made.id == edge)
            #expect(try await api.edgeTypes().contains { $0.id == edge })
            try await api.delete(edgeType: edge)
            #expect(try await !api.edgeTypes().contains { $0.id == edge })
        }
    }
}
