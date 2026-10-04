import Foundation
import Testing

@testable import Marfa

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveDeclaredTypes {
        private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String:
            JSONValue]
        {
            let server = try #require(Live.server)
            var request = URLRequest(url: server.url.appending(path: path))
            request.httpMethod = method
            request.setValue("Bearer \(server.key)", forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = try #require((response as? HTTPURLResponse)?.statusCode)
            try #require((200..<300).contains(status), "\(method) \(path) answered \(status)")
            return try JSONDecoder().decode([String: JSONValue].self, from: data)
        }

        private func key(for type: String, source: String, canRegister: Bool) async throws -> (
            id: String, server: Server
        ) {
            let metadata = canRegister ? ["types": "write", "tags": "write"] : ["tags": "write"]
            let types = canRegister ? [type: "write"] : [type: "write", "core.note": "write"]
            let minted = try await request(
                "POST", "keys",
                body: [
                    "label": "Swift declaration test", "source": source, "default_tier": "library",
                    "type_permissions": types, "metadata_permissions": metadata,
                ])
            return (
                try #require(minted["id"]?.string),
                Server(url: try #require(Live.server).url, key: try #require(minted["key"]?.string))
            )
        }

        private func definition(_ id: String) -> String {
            #"{"id":""# + id + #"","fields":{"title":{"type":"string","required":true}}}"#
        }

        @Test func aMinimalAppKeyRegistersAndDrainsAnOfflineCreate() async throws {
            let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let type = "app.swift\(suffix).entry"
            let minted = try await key(for: type, source: "swift-\(suffix)", canRegister: true)
            let copy = try await WorkingCopy.open(store: Live.store(), server: minted.server)
            do {
                try await copy.declareTypes([definition(type)])
                let queued = try await copy.items.create(
                    Draft(type: type, properties: ["title": "Offline"], tier: .library))
                let hydrated = try await copy.hydrate(types: [type], tier: .library)
                #expect(hydrated.registeredTypes == [type])
                #expect(hydrated.unregisteredTypes.isEmpty)
                #expect(try await copy.queue.all().contains { $0.id == queued.id && $0.verdict == nil })
                let drained = try await copy.queue.drain()
                #expect(drained.verdicts.first { $0.id == queued.id }?.verdict == .accepted)
                let itemId = try #require(queued.itemId)
                let item = try #require(try await copy.items.get(itemId))
                #expect(item.properties["title"] == "Offline")
                #expect(try await copy.queue.forgetAnswered() == 1)
                #expect(try await copy.queue.all().isEmpty)
                await copy.close()
                _ = try await request("DELETE", "keys/\(minted.id)")
            } catch {
                await copy.close()
                _ = try? await request("DELETE", "keys/\(minted.id)")
                throw error
            }
        }

        @Test func aRegistrationRefusalReportsItsCauseAndKeepsOfflineContent() async throws {
            let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let type = "app.swift\(suffix).entry"
            let minted = try await key(for: type, source: "swift-\(suffix)", canRegister: false)
            let copy = try await WorkingCopy.open(store: Live.store(), server: minted.server)
            do {
                try await copy.declareTypes([definition(type)])
                let queued = try await copy.items.create(
                    Draft(type: type, properties: ["title": "Kept"], tier: .library))
                let hydrated = try await copy.hydrate(types: ["core.note"], tier: .library)
                #expect(hydrated.registeredTypes.isEmpty)
                let refused = try #require(hydrated.unregisteredTypes.first)
                #expect(refused.id == type)
                #expect(refused.code == "forbidden")
                #expect(!refused.message.isEmpty)
                #expect(try await copy.declaredTypes().count == 1)
                #expect(try await copy.queue.all().contains { $0.id == queued.id && $0.verdict == nil })
                let itemId = try #require(queued.itemId)
                let item = try #require(try await copy.items.get(itemId))
                #expect(item.properties["title"] == "Kept")
                await copy.close()
                _ = try await request("DELETE", "keys/\(minted.id)")
            } catch {
                await copy.close()
                _ = try? await request("DELETE", "keys/\(minted.id)")
                throw error
            }
        }
    }
}
