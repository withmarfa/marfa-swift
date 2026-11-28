import Foundation
import MarfaAPI
import Testing

@testable import Marfa

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(1)))
    struct LiveStaleWrites {
        @Test func aStaleWebhookVersionIsRefusedAndTheCurrentOneIsAccepted() async throws {
            let api = Client(try #require(Live.server))
            let created = try await api.createWebhook(
                body: .json(
                    .init(
                        url: "https://example.com/marfa-swift-\(UUID().uuidString.lowercased())",
                        events: [.item_created])
                )
            ).created.body.json
            let id = created.id
            let first = created.version
            do {
                let moved = try await api.updateWebhook(
                    path: .init(id: id), body: .json(.init(active: false, version: first))
                ).ok.body.json
                #expect(moved.version == first + 1)
                #expect(moved.active == false)

                let stale = await #expect(throws: MarfaError.self) {
                    try await api.updateWebhook(path: .init(id: id), body: .json(.init(active: true, version: first)))
                }
                guard case .versionConflict? = stale else { throw NotAConflict(answer: stale) }
                #expect(stale?.currentVersion == first + 1)
                let held = try await api.getWebhook(path: .init(id: id)).ok.body.json
                #expect(held.value1.active == false, "the stale change wrote nothing")
                #expect(held.value1.version == first + 1)

                let current = try await api.updateWebhook(
                    path: .init(id: id), body: .json(.init(active: true, version: stale?.currentVersion))
                ).ok.body.json
                #expect(current.active && current.version == first + 2)
            } catch {
                _ = try? await api.deleteWebhook(path: .init(id: id))
                throw error
            }
            _ = try await api.deleteWebhook(path: .init(id: id))
        }

        @Test func aStaleTypeRevisionIsRefusedAndTheCurrentOneIsAccepted() async throws {
            let api = Client(try #require(Live.server))
            let id = "app.swift\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")).entry"
            let title = Components.Schemas.FieldDefinition(_type: .string, required: true)
            let notes = Components.Schemas.FieldDefinition(_type: .string)
            let registered = try await api.register(
                itemType: .init(fields: .init(additionalProperties: ["title": title]), id: id))
            let first = registered.value2.revision
            do {
                try await staleRevisionsAreRefused(api, id, first, title, notes)
            } catch {
                _ = try? await api.delete(itemType: id, force: true, revision: nil)
                throw error
            }
        }

        private func staleRevisionsAreRefused(
            _ api: Client, _ id: String, _ first: String,
            _ title: Components.Schemas.FieldDefinition, _ notes: Components.Schemas.FieldDefinition
        ) async throws {
            let replaced = try await api.replace(
                itemType: id,
                with: .init(fields: .init(additionalProperties: ["title": title, "notes": notes]), revision: first))
            let second = replaced.value2.revision
            #expect(second != first)

            let staleReplace = await #expect(throws: MarfaError.self) {
                try await api.replace(itemType: id, with: .init(fields: .init(), revision: first))
            }
            guard case .versionConflict? = staleReplace else { throw NotAConflict(answer: staleReplace) }
            #expect(staleReplace?.currentRevision == second)

            let staleDelete = await #expect(throws: MarfaError.self) {
                try await api.delete(itemType: id, force: true, revision: first)
            }
            #expect(staleDelete?.currentRevision == second)

            let held = try await api.replace(
                itemType: id,
                with: .init(
                    fields: .init(additionalProperties: ["title": title, "notes": notes]),
                    revision: staleReplace?.currentRevision))
            #expect(held.value1.fields.additionalProperties.keys.sorted() == ["notes", "title"], "the type survived")

            try await api.delete(itemType: id, revision: held.value2.revision)
            let gone = await #expect(throws: MarfaError.self) { try await api.delete(itemType: id, revision: nil) }
            #expect(gone?.code() == "not_found", "\(String(describing: gone))")
        }

        private struct NotAConflict: Error {
            let answer: MarfaError?
        }
    }
}
