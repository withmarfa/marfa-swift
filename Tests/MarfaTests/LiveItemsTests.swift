import Foundation
import Testing

@testable import Marfa

extension LiveWorkingCopies {
    /// Registering a type changes the read view every copy here hydrated
    /// under, so these run with the other structural suites.
    @Suite(
        .serialized,
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(3)))
    struct LiveItems {
        /// Sends JSON text as written, so the order of what it declares is
        /// the order the server reads.
        static func send(_ method: String, _ path: String, _ body: String? = nil) async throws -> (Int, String) {
            let server = try #require(Live.server)
            var request = URLRequest(url: server.url.appending(path: path))
            request.httpMethod = method
            request.setValue("Bearer \(server.key)", forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(body.utf8)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }

        /// What the server answers for an item, in the order it answers it.
        static func answered(_ id: String) async throws -> JSONObject? {
            let (status, body) = try await send("GET", "items/\(id)")
            guard status == 200 else { return nil }
            return try JSONObject(json: body)["item"]?.object
        }

        static func suffix() -> String {
            UUID().uuidString.lowercased().filter(\.isLetter).prefix(12).description
        }

        static func register(_ definition: String) async throws {
            let (status, body) = try await send("POST", "types", definition)
            try #require(status == 201, "registering a type answered \(status): \(body)")
        }

        static func hydrated(_ types: [String]) async throws -> WorkingCopy {
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await copy.hydrate(types: types, tier: .library)
            return copy
        }

        @Test func anItemShowsTheTitleAndBodyItsTypeNames() async throws {
            let session = "user.session_\(Self.suffix())"
            try await Self.register(
                #"{"id":"\#(session)","parent":"core.event","fields":{"transcript":{"type":"string"}},"display_hints":{"title_field":"title","body_field":"transcript"}}"#
            )
            let copy = try await Self.hydrated(["core.event"])
            let event = try #require(
                try await copy.items.create(
                    Draft(
                        type: "core.event",
                        properties: ["title": "Standup", "description": "Daily", "body": "not the event's body"],
                        tier: .library)
                ).itemId)
            let held = try #require(
                try await copy.items.create(
                    Draft(
                        type: session,
                        properties: ["title": "A session", "description": "the parent's body", "transcript": "said"],
                        tier: .library)
                ).itemId)
            #expect(try await copy.queue.drain().verdicts.map(\.verdict) == [.accepted, .accepted])

            let shownEvent = try #require(try await copy.items.get(event))
            #expect(shownEvent.title == "Standup")
            #expect(shownEvent.body == "Daily", "an event's body was read from somewhere other than its description")
            let shownSession = try #require(try await copy.items.get(held))
            #expect(shownSession.body == "said", "a subtype's own body field lost to its parent's")
            let listed = try await copy.items.list(ListFilters(type: session))
            #expect(listed.map(\.body) == ["said"])
            let found = try await copy.search("session", filters: SearchFilters(type: session))
            #expect(found.first?.item.title == "A session")
            await copy.close()
        }

        @Test func propertiesKeepTheServersOrderBeforeAndAfterTheAnswer() async throws {
            let type = "user.ordered_\(Self.suffix())"
            try await Self.register(
                #"{"id":"\#(type)","fields":{"zeta":{"type":"string"},"alpha":{"type":"string"},"mid":{"type":"string"}}}"#
            )
            let copy = try await Self.hydrated([type])
            let sent: JSONObject = ["extra": "x", "mid": "m", "10": "ten", "zeta": "z", "2": "two", "alpha": "a"]
            let id = try #require(
                try await copy.items.create(Draft(type: type, properties: sent, tier: .library)).itemId)
            let order = ["2", "10", "zeta", "alpha", "mid", "extra"]
            // The witness: the order sent is neither this one nor alphabetical.
            #expect(sent.keys != order)
            #expect(try await copy.items.get(id)?.properties.keys == order)
            _ = try await copy.queue.drain()
            #expect(try await Self.answered(id)?["properties"]?.object?.keys == order)
            #expect(try await copy.items.get(id)?.properties.keys == order)

            // An edit not yet sent moves no key, and adds after them.
            let held = try #require(try await copy.items.get(id))
            _ = try await copy.items.update(id, Edit(.merge(["new": "n", "zeta": "z2"]), baseVersion: held.version))
            let edited = order + ["new"]
            #expect(try await copy.items.get(id)?.properties.keys == edited)
            #expect(try await copy.queue.drain().verdicts.map(\.verdict) == [.accepted])
            #expect(try await Self.answered(id)?["properties"]?.object?.keys == edited)
            #expect(try await copy.items.get(id)?.properties.keys == edited)
            await copy.close()
        }

        @Test func anEditMovesAndReplacesOnline() async throws {
            let copy = try await Self.hydrated(["core.note"])
            let id = try #require(
                try await copy.items.create(
                    Draft(type: "core.note", properties: ["title": "t", "body": "b", "notes": "n"], tier: .library)
                ).itemId)
            _ = try await copy.queue.drain()
            let held = try #require(try await copy.items.get(id))
            _ = try await copy.items.update(id, Edit(.replace(["body": "only"]), baseVersion: held.version))
            #expect(try await copy.queue.drain().verdicts.map(\.verdict) == [.accepted])
            #expect(try await Self.answered(id)?["properties"] == .object(["body": "only"]))

            // A type the copy's catalog does not hold is refused before
            // anything is queued.
            let queued = try await copy.queue.all().count
            let now = try #require(try await copy.items.get(id))
            await #expect {
                _ = try await copy.items.update(id, Edit(baseVersion: now.version, type: "user.nothing_held_here"))
            } throws: { error in
                if case MarfaError.unknownType = error { true } else { false }
            }
            #expect(try await copy.queue.all().count == queued)

            _ = try await copy.items.update(
                id, Edit(.merge(["title": "a task"]), baseVersion: now.version, type: "core.task", tier: .feed))
            // A retype changes what the copy's read view covers, so the read
            // after the answer expires the copy (device.md 52): the write is
            // answered, and the app hydrates again.
            await #expect {
                _ = try await copy.queue.drain()
            } throws: { error in
                if case MarfaError.copyExpired(reason: "read_view_changed", _) = error { true } else { false }
            }
            #expect(try await copy.queue.all().map(\.verdict).allSatisfy { $0 == .accepted })
            let moved = try #require(try await Self.answered(id))
            #expect(moved["type"] == "core.task")
            #expect(moved["tier"] == "feed")
            _ = try await copy.hydrate(types: ["core.note"], tier: .library)
            #expect(try await copy.items.get(id) == nil, "a row moved out of the slice was still held")
            await copy.close()
        }

        /// Every page of the bin until `id` is found or the bin ends.
        static func inBin(_ copy: WorkingCopy, _ id: String) async throws -> Item? {
            var cursor: String?
            var pages = 0
            repeat {
                let page = try await copy.items.bin(type: "core.note", after: cursor, limit: 100)
                if let found = page.items.first(where: { $0.id == id }) { return found }
                cursor = page.nextCursor
                pages += 1
            } while cursor != nil && pages < 100
            return nil
        }

        @Test func theBinIsReadRestoredFromAndPurged() async throws {
            let copy = try await Self.hydrated(["core.note"])
            let id = try #require(
                try await copy.items.create(
                    Draft(type: "core.note", properties: ["title": "to the bin", "body": "b"], tier: .library)
                ).itemId)
            _ = try await copy.queue.drain()
            await #expect {
                try await copy.items.purge(id)
            } throws: { error in
                if case MarfaError.validation(code: "invalid_transition", _) = error { true } else { false }
            }
            _ = try await copy.items.delete(id)
            _ = try await copy.queue.drain()
            _ = try await copy.queue.forgetAnswered()

            let binned = try #require(try await Self.inBin(copy, id), "the deleted item was not in the bin")
            #expect(binned.state == .trashed)
            #expect(binned.title == "to the bin")
            await #expect {
                _ = try await copy.pin(id)
            } throws: { error in
                if case MarfaError.notFound(code: "trashed", _) = error { true } else { false }
            }

            // Restored by id, whether or not the copy still holds it.
            let restored = try await copy.items.restore(id)
            #expect(restored.kind == .restoreItem)
            #expect(try await copy.queue.drain().verdicts.map(\.verdict) == [.accepted])
            _ = try await copy.catchUp()
            #expect(try await copy.items.get(id)?.state == .active)
            #expect(try await Self.inBin(copy, id) == nil)

            _ = try await copy.items.delete(id)
            _ = try await copy.queue.drain()
            _ = try await copy.queue.forgetAnswered()
            _ = try await copy.catchUp()
            let again = try #require(try await Self.inBin(copy, id))
            try await copy.items.purge(id, version: again.version)
            #expect(try await Self.inBin(copy, id) == nil)
            #expect(try await Self.answered(id) == nil)
            #expect(try await copy.items.get(id) == nil)
            #expect(try await copy.queue.all().isEmpty)
            await copy.close()
        }
    }
}
