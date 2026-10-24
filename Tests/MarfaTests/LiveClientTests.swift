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

        private static func suffix() -> String {
            UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        }

        @Test func anEdgeTypeNamesBothEndsAndAnUnregisteredReverseLabelIsTheLabel() async throws {
            let api = Client(try #require(Live.server))
            let one = "app.swift\(Self.suffix()).parent"
            let two = "app.swift\(Self.suffix()).related"

            let named = try await api.register(
                edgeType: .init(id: one, label: "Children", reverseLabel: "Parent", cardinality: .oneToMany))
            #expect(named.label == "Children" && named.reverseLabel == "Parent")
            let alike = try await api.register(edgeType: .init(id: two, label: "Related to", cardinality: .manyToMany))
            #expect(alike.reverseLabel == "Related to", "no reverse label, so the label names both ends")

            let listed = try await api.edgeTypes()
            #expect(listed.first { $0.id == one }?.reverseLabel == "Parent")
            #expect(listed.first { $0.id == two }?.reverseLabel == "Related to")

            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await copy.hydrate(types: ["core.note"], tier: .all, edgeTypes: [one, two])
            let held = try await copy.catalog.edgeType(one)
            #expect(held.label == "Children" && held.reverseLabel == "Parent")
            #expect(try await copy.catalog.edgeType(two).reverseLabel == "Related to")
            for id in [one, two] { try await api.delete(edgeType: id) }
            await copy.close()
        }

        /// A type holding `count` items, and a second to move them to.
        private static func movable(_ api: Client, count: Int) async throws -> (from: String, to: String) {
            let name = Self.suffix()
            let title = Components.Schemas.FieldDefinition(_type: .string)
            let fields = Components.Schemas.TypeDefinitionInput.FieldsPayload(additionalProperties: ["title": title])
            let from = "app.swift\(name).old"
            let to = "app.swift\(name).new"
            _ = try await api.register(itemType: .init(fields: fields, id: from))
            _ = try await api.register(itemType: .init(fields: fields, id: to))
            let server = try #require(Live.server)
            var request = URLRequest(url: server.url.appending(path: "items/bulk"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(server.key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let items: [JSONValue] = (0..<count).map {
                ["type": .string(from), "properties": ["title": .string("t\($0)")]]
            }
            let payload: JSONObject = ["items": .array(items)]
            request.httpBody = Data(try payload.json().utf8)
            let (body, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            try #require(
                status == 200,
                "creating \(count) items answered \(status ?? 0): \(String(decoding: body, as: UTF8.self))")
            return (from, to)
        }

        @Test func aMoveIsPreviewedThenRunAndFollowedToItsResult() async throws {
            let api = Client(try #require(Live.server))
            let (from, to) = try await Self.movable(api, count: 3)

            let preview = try await api.previewMove(ofType: from, to: to)
            #expect(preview.dryRun && preview.matched == 3 && preview.ids.count == 3)
            let again = try await api.previewMove(ofType: from, to: to)
            #expect(again.matched == 3, "the preview moved nothing")

            let started = try await api.startMove(ofType: from, to: to)
            #expect(started.action == "type_move")
            let job = try await api.follow(moveJob: started.id)
            #expect(job.status == .completed)
            let result = try #require(job.result)
            #expect(result.succeeded == 3 && result.remaining == 0 && result.remainingHidden == false)
            #expect(result.settingsRewritten == true)
            #expect(try await api.previewMove(ofType: from, to: to).matched == 0, "nothing is left to move")

            try await api.delete(itemType: from)
            try await api.delete(itemType: to, force: true)
        }

        @Test func aMoveCancelledPartwayLeavesItsSettingsAndARerunFinishesIt() async throws {
            let api = Client(try #require(Live.server))
            let (from, to) = try await Self.movable(api, count: 600)
            let view = try await Live.writeView([
                "title": .string("Moving \(Self.suffix())"), "query": ["types": [.string(from)]],
            ])

            let started = try await api.startMove(ofType: from, to: to)
            let stopped = try await api.cancel(moveJob: started.id)
            let ended = try await api.follow(moveJob: stopped.id)
            #expect(ended.status == .canceled, "\(ended)")
            #expect(ended.succeeded < 600, "it stopped before the end")
            let afterwards = try await api.previewMove(ofType: from, to: to)
            #expect(afterwards.matched == 600 - ended.succeeded, "what it moved stays moved")
            #expect(afterwards.settings.contains { $0.id == view }, "no setting was rewritten")

            let finished = try await api.follow(moveJob: try await api.startMove(ofType: from, to: to).id)
            #expect(finished.status == .completed && finished.result?.remaining == 0)
            #expect(finished.result?.settingsRewritten == true)

            let done = try await api.cancel(moveJob: finished.id)
            #expect(done.status == .completed, "the witness: a job that ended is answered as it ended")
            try await Live.deleteView(view)
            try await api.delete(itemType: from)
            try await api.delete(itemType: to, force: true)
        }

        @Test func aDeleteRefusedWhileAViewNamesTheTypeSaysWhichViewDoes() async throws {
            let api = Client(try #require(Live.server))
            let (from, to) = try await Self.movable(api, count: 0)
            let view = try await Live.writeView([
                "title": .string("Names \(Self.suffix())"), "query": ["types": [.string(from)]],
            ])

            let refused = await #expect(throws: MarfaError.self) { try await api.delete(itemType: from) }
            guard case .server(let status, let code, let message)? = refused else {
                Issue.record("refused as \(String(describing: refused))")
                return
            }
            #expect(status == 409 && code == "type_in_use")
            #expect(message.contains(view) && message.contains("query.types"), "\(message)")

            try await api.delete(itemType: to)  // the witness: a type no setting names is deleted

            try await Live.deleteView(view)
            try await api.delete(itemType: from)
        }
    }
}
