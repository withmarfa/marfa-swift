import CryptoKit
import Foundation
import Testing

@testable import Marfa

enum Live {
    static let named = Result { try Server.fromEnvironment() }
    static var server: Server? { try? named.get() }

    static func store() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "marfa-live-\(UUID()).sqlite")
    }

    static func file(_ text: String, named name: String = "marfa-live-\(UUID()).txt") throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: name)
        try Data(text.utf8).write(to: file)
        return file
    }

    static func hydrated(_ store: URL = store()) async throws -> WorkingCopy {
        let copy = try await WorkingCopy.open(store: store, server: server)
        _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
        return copy
    }

    static func note(_ title: String, tags: [String] = [], occurredAt: String? = nil) -> Draft {
        Draft(
            type: "core.note", properties: ["title": .string(title), "body": "b"], tags: tags, tier: .feed,
            occurredAt: occurredAt)
    }

    /// Writes fixture definitions directly, including edge types the copy cannot declare.
    static func writeDefinition(_ definition: [String: Any], at path: String = "types", method: String = "POST")
        async throws
    {
        guard let server else {
            Issue.record("no server to register a type on")
            return
        }
        var request = URLRequest(url: server.url.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(server.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: definition)
        let (body, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        try #require(
            status == (method == "POST" ? 201 : 200),
            "writing at \(path) answered \(status ?? 0): \(String(decoding: body, as: UTF8.self))")
    }

    /// What the server answers, read past the working copy.
    static func read(_ path: String, query: [URLQueryItem] = []) async throws -> JSONObject {
        let server = try #require(server)
        var request = URLRequest(url: server.url.appending(path: path).appending(queryItems: query))
        request.setValue("Bearer \(server.key)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        try #require(status == 200, "reading \(path) answered \(status ?? 0): \(String(decoding: body, as: UTF8.self))")
        return try JSONObject(json: String(decoding: body, as: UTF8.self))
    }

    /// Every edge type the server lists, by id.
    static func edgeTypes() async throws -> [String: JSONObject] {
        var listed: [String: JSONObject] = [:]
        var cursor: String?
        repeat {
            let page = try await read(
                "edge-types", query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
            guard case .array(let rows) = page["data"] else {
                Issue.record("the edge type listing held no data: \(page)")
                return listed
            }
            for case .object(let edgeType) in rows {
                if let id = edgeType["id"]?.string { listed[id] = edgeType }
            }
            cursor = page["next_cursor"]?.string
        } while cursor != nil
        return listed
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MARFA_LIVE_REQUIRED"] != nil), .timeLimit(.minutes(1)))
func theLiveTestsHaveAServerWhereTheyAreRequired() {
    #expect(throws: Never.self) { try Live.named.get() }
    #expect(Live.server != nil, "MARFA_LIVE_REQUIRED is set, and MARFA_API_URL or MARFA_API_KEY is not")
}

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveServer {
        @Test func edgeTypesHoldIncomingEdgesAndPinsHoldTheirRows() async throws {
            let writer = try await Live.hydrated()
            let note = try #require(try await writer.items.create(Live.note("held attachment \(UUID())")).itemId)
            let attachment = try await writer.items.attach(to: note, file: try Live.file("attachment options"))
            let file = try #require(attachment.item.itemId)
            let drained = try await writer.queue.drain()
            #expect(drained.verdicts.allSatisfy { $0.verdict == .accepted })

            let ordinary = try await Live.hydrated()
            #expect(try await ordinary.items.get(note) != nil)
            #expect(try await ordinary.items.get(file) == nil)
            #expect(try await !ordinary.edges.to(note).contains { $0.sourceId == file })
            #expect(try await ordinary.pin(file) == PinReport(pinned: true, wasPinned: false))
            #expect(try await ordinary.items.get(file) != nil)
            #expect(try await ordinary.edges.to(note).contains { $0.sourceId == file })
            #expect(try await ordinary.status().pinned.contains(file))
            #expect(try await ordinary.unpin(file) == PinReport(pinned: false, wasPinned: true))
            #expect(try await ordinary.items.get(file) == nil)

            let whole = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            let report = try await whole.hydrate(types: ["core.note"], tier: .feed, edgeTypes: ["attached-to"])
            #expect(report.edgeTypes == ["attached-to"])
            #expect(try await whole.status().sliceEdgeTypes == ["attached-to"])
            #expect(try await whole.items.get(file) == nil)
            #expect(try await whole.edges.to(note).contains { $0.sourceId == file })
            _ = try await whole.pin(file)
            #expect(try await whole.items.get(file) != nil)
            _ = try await whole.unpin(file)
            #expect(try await whole.items.get(file) == nil)
            #expect(try await whole.edges.to(note).contains { $0.sourceId == file })
            await writer.close()
            await ordinary.close()
            await whole.close()
        }

        @Test func listingAndSearchApplyFilterAndBeneath() async throws {
            let writer = try await Live.hydrated()
            let root = try #require(
                try await writer.items.create(Live.note("bounded root \(UUID())", tags: ["root"])).itemId)
            let child = try #require(
                try await writer.items.create(Live.note("bounded child \(UUID())", tags: ["child"])).itemId)
            let outside = try #require(
                try await writer.items.create(Live.note("bounded outside \(UUID())", tags: ["child"])).itemId)
            _ = try await writer.edges.create(from: root, to: child, type: "parent-of")
            #expect(try await writer.queue.drain().verdicts.allSatisfy { $0.verdict == .accepted })
            let reader = try await Live.hydrated()
            #expect(Set(try await reader.items.list(ListFilters(beneath: root)).map(\.id)) == Set([root, child]))
            #expect(try await reader.items.get(outside) != nil)
            #expect(
                try await reader.items.list(ListFilters(filter: "tags contains \"child\"", beneath: root)).map(\.id)
                    == [
                        child
                    ])
            #expect(
                Set(try await reader.search("bounded", filters: SearchFilters(beneath: root)).map(\.item.id))
                    == Set([root, child]))
            #expect(
                try await reader.search(
                    "bounded", filters: SearchFilters(filter: "tags contains \"child\"", beneath: root)
                )
                .map(\.item.id) == [child])
            await writer.close()
            await reader.close()
        }

        @Test func aSliceOfBothTiersKeepsAnItemTriagedWithNoServer() async throws {
            let store = Live.store()
            let writer = try await WorkingCopy.open(store: store, server: Live.server)
            let hydrated = try await writer.hydrate(types: ["core.note"], tier: .all)
            #expect(hydrated.tier == .all)
            #expect(try await writer.status().sliceTier == .all)
            let inbox = try #require(try await writer.items.create(Live.note("inbox \(UUID())")).itemId)
            let record = try #require(
                try await writer.items.create(
                    Draft(type: "core.note", properties: ["title": .string("record \(UUID())"), "body": "b"])
                ).itemId)
            #expect(try await writer.queue.drain().verdicts.allSatisfy { $0.verdict == .accepted })
            #expect(try await writer.items.get(inbox)?.tier == .feed)
            #expect(try await writer.items.get(record)?.tier == .library)
            let version = try #require(try await writer.items.get(inbox)).version
            await writer.close()

            let offline = try await WorkingCopy.open(store: store)
            _ = try await offline.items.update(inbox, Edit(baseVersion: version, tier: .library))
            #expect(try await offline.items.get(inbox)?.tier == .library)
            #expect(try await !offline.items.list(ListFilters(tier: .feed)).contains { $0.id == inbox })
            #expect(try await offline.items.list(ListFilters(tier: .library)).contains { $0.id == inbox })
            await offline.close()

            let online = try await WorkingCopy.open(store: store, server: Live.server)
            #expect(try await online.queue.drain().verdicts.allSatisfy { $0.verdict == .accepted })
            _ = try await online.catchUp()
            #expect(try await online.items.get(inbox)?.tier == .library)
            let answered = try await Live.read("items/\(inbox)")
            guard case .object(let item) = answered["item"] else {
                Issue.record("the server answered no item for \(inbox): \(answered)")
                return
            }
            #expect(item["tier"] == "library")
            await online.close()
        }

        @Test func aWriteMadeHereIsAnsweredAndHeld() async throws {
            let copy = try await Live.hydrated()
            let title = "Live \(UUID())"
            let created = try await copy.items.create(Live.note(title))
            let tagged = try await copy.tags.add("favorite", to: created.itemId ?? "")
            let twin = try await copy.items.create(Live.note(title))
            let report = try await copy.queue.drain()
            let verdicts = report.verdicts.filter { [created.id, tagged.id, twin.id].contains($0.id) }.map(\.verdict)
            #expect(verdicts == [.accepted, .accepted, .accepted])
            let both = try await copy.search(title, filters: SearchFilters(type: "core.note"))
            #expect(both.count == 2)
            let found = try await copy.search(title, filters: SearchFilters(type: "core.note", tags: ["favorite"]))
            #expect(found.map(\.item.id) == [created.itemId])
        }

        @Test func aThumbnailIsReadFromTheHeldRow() async throws {
            let type = "user.snapshot\(UUID().uuidString.prefix(8).lowercased())"
            try await Live.writeDefinition([
                "id": type, "fields": ["title": ["type": "string"], "thumbnail": ["type": "thumbnail"]],
            ])
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await copy.hydrate(types: [type], tier: .feed)
            let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("snapshot".utf8)
            let with = try await copy.items.create(
                Draft(
                    type: type,
                    properties: [
                        "title": "With an image",
                        "thumbnail": .string("data:image/png;base64,\(bytes.base64EncodedString())"),
                    ], tier: .feed))
            let without = try await copy.items.create(Draft(type: type, properties: ["title": "Without"], tier: .feed))
            let report = try await copy.queue.drain()
            let verdicts = report.verdicts.filter { [with.id, without.id].contains($0.id) }.map(\.verdict)
            #expect(verdicts == [.accepted, .accepted])
            let withId = try #require(with.itemId)
            let withoutId = try #require(without.itemId)
            let thumbnail = try #require(try await copy.items.thumbnail(withId))
            #expect(thumbnail.mimeType == "image/png")
            #expect(thumbnail.bytes == bytes)
            #expect(try await copy.items.thumbnail(withoutId) == nil)
        }

        @Test func attachedBytesAreFetchedByAStoreThatNeverHeldThem() async throws {
            let copy = try await Live.hydrated()
            let note = try await copy.items.create(Live.note("with a file"))
            let text = "bytes \(UUID())\n"
            let attached = try await copy.items.attach(to: note.itemId ?? "", file: try Live.file(text))
            let hash = try #require(attached.upload.blob)
            #expect(try await copy.blobs.isHeld(hash))
            let report = try await copy.queue.drain()
            let answered = Dictionary(
                report.verdicts.map { ($0.id, $0.verdict) }, uniquingKeysWith: { first, _ in first })
            for write in [note, attached.upload, attached.item, attached.edge] {
                #expect(
                    answered[write.id] == .accepted,
                    "\(write.kind) was answered \(String(describing: answered[write.id]))")
            }

            let fresh = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            #expect(try await !fresh.blobs.isHeld(hash))
            let fetched = try await fresh.blobs.get(hash)
            #expect(try Data(contentsOf: fetched) == Data(text.utf8))
            #expect(try await fresh.blobs.isHeld(hash))
        }

        /// The server answers `404 blob_not_found` for bytes it holds none of,
        /// as it does for bytes beyond the credential's reach.
        @Test func bytesTheServerHoldsNoneOfAreAbsentAndTheItemStaysWhole() async throws {
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await copy.hydrate(types: ["core.file"], tier: .feed)
            let hash =
                "sha256:" + SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
            let file = try await copy.items.create(
                Draft(
                    type: "core.file",
                    properties: ["title": "names absent bytes", "blob_ref": .string(hash), "mime_type": "text/plain"],
                    tier: .feed))
            let report = try await copy.queue.drain()
            #expect(report.verdicts.first { $0.id == file.id }?.verdict == .accepted)
            let id = try #require(file.itemId)
            await #expect {
                _ = try await copy.blobs.get(hash)
            } throws: { error in
                guard case Marfa.MarfaError.bytesAbsent(let absent, _, _) = error else { return false }
                return absent == hash
            }
            #expect(try await !copy.blobs.isHeld(hash))
            let held = try #require(try await copy.items.get(id))
            #expect(held.title == "names absent bytes")
            #expect(held.properties["blob_ref"] == .string(hash))
            #expect(held.state == .active)
        }

        @Test func eachVerdictArrivesTyped() async throws {
            let copy = try await Live.hydrated()
            let titled = try await copy.items.create(
                Draft(type: "core.note", properties: ["title": "first", "body": "first"], tier: .feed))
            let bodied = try await copy.items.create(
                Draft(type: "core.note", properties: ["title": "other", "body": "first"], tier: .feed))
            let refused = try await copy.items.create(
                Draft(
                    type: "system.connection",
                    properties: ["kind": "app", "status": "active", "granted_at": "2026-01-01T00:00:00Z"]))
            var report = try await copy.queue.drain()
            #expect(report.verdicts.first { $0.id == titled.id }?.verdict == .accepted)
            guard case .refused(let refusal) = report.verdicts.first(where: { $0.id == refused.id })?.verdict else {
                Issue.record("the write to a type the key cannot write was not refused: \(report.verdicts)")
                return
            }
            #expect(refusal.reason == "type_not_permitted")
            #expect(refusal.code == "type_not_permitted")
            let titledId = try #require(titled.itemId)
            let bodiedId = try #require(bodied.itemId)

            // Two notes, because two edits to one note wait on each other and
            // the second is sent only on the first's answer.
            let elsewhere = try await Live.hydrated()
            _ = try await copy.items.update(titledId, Edit(.merge(["title": "second"]), baseVersion: 1))
            _ = try await copy.items.update(bodiedId, Edit(.merge(["body": "second"]), baseVersion: 1))
            report = try await copy.queue.drain()
            let merged = try await elsewhere.items.update(
                titledId, Edit(.merge(["title": "third"]), baseVersion: 1))
            let conflicted = try await elsewhere.items.update(
                bodiedId, Edit(.merge(["body": "elsewhere"]), baseVersion: 1))
            report = try await elsewhere.queue.drain()
            #expect(report.verdicts.first { $0.id == merged.id }?.verdict == .merged(fields: ["title"]))
            guard case .conflicted(_, let fields) = report.verdicts.first(where: { $0.id == conflicted.id })?.verdict
            else {
                Issue.record("the stale body edit was not conflicted: \(report.verdicts)")
                return
            }
            #expect(fields == ["body"])
        }

        @Test func anEditBasedOnAnEarlierReadIsMerged() async throws {
            let copy = try await Live.hydrated()
            let note = try await copy.items.create(Live.note("read here"))
            _ = try await copy.queue.drain()
            let id = try #require(note.itemId)
            let read = try #require(try await copy.items.get(id))

            let elsewhere = try await Live.hydrated()
            _ = try await elsewhere.items.update(
                id, Edit(.merge(["title": "retitled elsewhere"]), baseVersion: read.version))
            _ = try await elsewhere.queue.drain()
            _ = try await copy.catchUp()
            let held = try #require(try await copy.items.get(id))
            #expect(held.version > read.version, "the copy did not take in the retitle")

            let edit = Edit(.merge(["body": "written here"]), baseVersion: read.version)
            await #expect {
                _ = try await copy.items.update(id, edit)
            } throws: { error in
                guard case Marfa.MarfaError.invalid(let message) = error else { return false }
                return message.contains("based on version \(read.version)")
            }
            let saved = try await copy.items.updateAsRead(id, edit)
            let next = try await copy.items.update(
                id, Edit(.merge(["body": "written here, then more"]), baseVersion: held.version))
            let report = try await copy.queue.drain()
            // `merged` names a collision the server resolved, and none happened.
            #expect(report.verdicts.first { $0.id == saved.id }?.verdict == .accepted)
            #expect(report.verdicts.first { $0.id == next.id }?.verdict == .accepted)
            let answered = try #require(try await copy.items.get(id))
            #expect(answered.properties["title"] == "retitled elsewhere")
            #expect(answered.properties["body"] == "written here, then more")
        }

        @Test func writesUnderARefusedKeyAreBlockedAndReleased() async throws {
            let store = Live.store()
            // Gone before the store opens again, so the second open is the writer.
            let id = try await { () async throws -> String in
                let copy = try await Live.hydrated(store)
                let note = try await copy.items.create(Live.note("keyed"))
                _ = try await copy.queue.drain()
                return try #require(note.itemId)
            }()
            let refusedKey = try #require(Live.server).with(key: "mk_not_a_key")
            let unkeyed = try await WorkingCopy.open(store: store, server: refusedKey)
            let first = try await unkeyed.tags.add("favorite", to: id)
            let second = try await unkeyed.tags.add("pinned", to: id)
            _ = try await unkeyed.queue.drain()
            func verdict(_ write: QueuedWrite) async throws -> Verdict? {
                try await unkeyed.queue.all().first { $0.id == write.id }?.verdict
            }
            guard case .blocked(let reason, let refusal) = try await verdict(first) else {
                Issue.record("the refused credential did not block its write")
                return
            }
            #expect(reason == .credentialRefused)
            #expect(refusal?.code == "unauthorized")
            #expect(refusal?.message == "Authentication required")
            #expect(try await verdict(second) == .blocked(reason: .credentialRefused))
            #expect(try await unkeyed.queue.release(first.id))
            #expect(try await verdict(first) == nil)
            #expect(try await unkeyed.queue.release(reason: .credentialRefused) == 1)
            #expect(try await verdict(second) == nil)
        }

        @Test func aWithdrawTakesNoWriteThatCanStillBeSent() async throws {
            let copy = try await Live.hydrated()
            let note = try await copy.items.create(Live.note("not withdrawn"))
            let heard = Heard(copy.changes())
            #expect(try await copy.queue.withdraw(note.id) == false)
            #expect(try await copy.queue.all().contains { $0.id == note.id })
            await #expect {
                _ = try await copy.queue.withdraw("not-a-queued-write")
            } throws: { error in
                if case Marfa.MarfaError.notFound = error { true } else { false }
            }
            try await Task.sleep(for: .milliseconds(300))
            #expect(!heard.all.contains(Change(origin: .refreshed(.withdrawn), itemId: nil, edgeId: nil)))
            try await bounded("close") { await copy.close() }
        }

        @Test func eachWriteIsToldOnceAsTheWriteItWas() async throws {
            let copy = try await Live.hydrated()
            let heard = Heard(copy.changes())
            var writes: [QueuedWrite] = []
            func record(_ write: QueuedWrite) -> QueuedWrite {
                writes.append(write)
                return write
            }
            let a = try #require(record(try await copy.items.create(Live.note("told a"))).itemId)
            let b = try #require(record(try await copy.items.create(Live.note("told b"))).itemId)
            let version = try #require(try await copy.items.get(a)).version
            _ = record(
                try await copy.items.update(a, Edit(.merge(["title": "told a, edited"]), baseVersion: version)))
            _ = record(try await copy.tags.add("told", to: a))
            _ = record(try await copy.tags.remove("told", from: a))
            _ = record(try await copy.metadata.replaceTags(of: a, with: ["x"]))
            _ = record(try await copy.metadata.mergeTags(["y"], into: a))
            _ = record(try await copy.extensions.write("told", ["k": 1], on: a))
            _ = record(try await copy.extensions.delete("told", from: a))
            let edge = record(try await copy.edges.create(from: a, to: b, type: "references"))
            let edgeId = try #require(edge.edgeId)
            #expect(edge.targetId != edgeId)
            let edgeVersion = try #require(try await copy.edges.from(a).first).version
            _ = record(try await copy.edges.update(edgeId, EdgeEdit(baseVersion: edgeVersion)))
            _ = record(try await copy.edges.delete(edgeId))
            _ = record(try await copy.items.transition(b, to: .archived))
            _ = record(try await copy.items.delete(b))
            _ = record(try await copy.items.restore(b))
            _ = record(try await copy.blobs.put(file: try Live.file("put \(UUID())")))
            let attached = try await copy.items.attach(to: a, file: try Live.file("attached \(UUID())"))
            writes += [attached.upload, attached.item, attached.edge]

            let expected = writes.map { Change(origin: .local($0.kind), itemId: $0.itemId, edgeId: $0.edgeId) }
            try await eventually("every write was told") { heard.locals.count >= expected.count }
            try await Task.sleep(for: .milliseconds(300))
            #expect(heard.locals == expected)
            try await bounded("close") { await copy.close() }
        }

        @Test func eachWriteDoesWhatItNames() async throws {
            let copy = try await Live.hydrated()
            let a = try #require(try await copy.items.create(Live.note("named a")).itemId)
            let b = try #require(try await copy.items.create(Live.note("named b")).itemId)
            func tags() async throws -> Set<String> { Set(try #require(try await copy.items.get(a)).tags) }

            _ = try await copy.tags.add("x", to: a)
            _ = try await copy.tags.add("y", to: a)
            #expect(try await tags() == ["x", "y"])
            _ = try await copy.tags.remove("x", from: a)
            #expect(try await tags() == ["y"])
            _ = try await copy.metadata.mergeTags(["z"], into: a)
            #expect(try await tags() == ["y", "z"])
            _ = try await copy.metadata.replaceTags(of: a, with: ["w"])
            #expect(try await tags() == ["w"])

            let wrote = try await copy.extensions.write("named", ["k": 1], on: a)
            #expect(wrote.kind == .writeExtension)
            let deleted = try await copy.extensions.delete("named", from: a)
            #expect(deleted.kind == .deleteExtension)
            #expect(deleted.namespace == "named")

            _ = try await copy.items.transition(a, to: .archived)
            #expect(try await copy.items.get(a)?.state == .archived)
            _ = try await copy.items.delete(b)
            #expect(try await copy.items.get(b) == nil)
            _ = try await copy.items.restore(b)
            #expect(try await copy.items.get(b)?.state == .active)

            let edgeId = UUID().uuidString.lowercased()
            let linked = try await copy.edges.create(from: a, to: b, type: "references", id: edgeId)
            #expect(linked.edgeId == edgeId)
            let from = try await copy.edges.from(a)
            #expect(from.map(\.id) == [edgeId])
            #expect(from.map(\.targetId) == [b])
            #expect(try await copy.edges.from(b).isEmpty)
            let to = try await copy.edges.to(b)
            #expect(to.map(\.id) == [edgeId])
            #expect(try await copy.edges.to(a).isEmpty)
            let ofType = try await copy.edges.ofType("references")
            #expect(ofType.contains { $0.id == edgeId }, "an edge still queued was left out of its type's read")
            #expect(ofType.allSatisfy { $0.edgeType == "references" })
            #expect(try await copy.edges.ofType("in-thread").contains { $0.id == edgeId } == false)
            let held = try #require(from.first).version
            await #expect {
                _ = try await copy.edges.update(edgeId, EdgeEdit(baseVersion: held + 7))
            } throws: { error in
                guard case Marfa.MarfaError.invalid(let message) = error else { return false }
                return message.contains("version \(held + 7)")
            }
            let updated = try await copy.edges.update(edgeId, EdgeEdit(baseVersion: held))
            #expect(updated.baseVersion == held)
        }

        @Test func anUploadAndAnAttachmentKeepWhatTheyWereGiven() async throws {
            let copy = try await Live.hydrated()
            let note = try #require(try await copy.items.create(Live.note("given")).itemId)

            let given = try await copy.blobs.put(file: try Live.file("given \(UUID())"), mimeType: "text/markdown")
            let guessed = try await copy.blobs.put(file: try Live.file("guessed \(UUID())"))
            _ = try await copy.queue.drain()
            let answered = try await copy.queue.all()
            func mimeType(_ write: QueuedWrite) throws -> JSONValue? {
                let row = try #require(answered.first { $0.id == write.id })
                #expect(row.verdict == .accepted)
                return try JSONObject(json: try #require(row.answer))["mime_type"]
            }
            #expect(try mimeType(given) == "text/markdown")
            #expect(try mimeType(guessed) == "text/plain")

            let attached = try await copy.items.attach(
                to: note, file: try Live.file("attached \(UUID())"),
                Attachment(mimeType: "text/csv", title: "Given title"))
            let fileId = try #require(attached.item.itemId)
            let file = try #require(try await copy.items.get(fileId))
            #expect(file.title == "Given title")
            #expect(file.properties["mime_type"] == "text/csv")
            let name = "plain-\(UUID()).txt"
            let plain = try await copy.items.attach(to: note, file: try Live.file("plain", named: name))
            let plainId = try #require(plain.item.itemId)
            let plainFile = try #require(try await copy.items.get(plainId))
            #expect(plainFile.title == name)
            #expect(plainFile.properties["mime_type"] == "text/plain")
        }

        @Test func searchAndListNarrowAsAsked() async throws {
            let copy = try await Live.hydrated()
            let word = "heron\(UUID().uuidString.prefix(8).lowercased())"
            let tag = "narrow-\(UUID())"
            var ids: [String] = []
            for day in 1...3 {
                let written = try await copy.items.create(
                    Live.note("\(word) \(day)", tags: [tag], occurredAt: "2026-01-0\(day)T00:00:00.000Z"))
                ids.append(try #require(written.itemId))
            }
            #expect(try await copy.search(word).count == 3)
            #expect(try await copy.search(word, limit: 2).count == 2)

            let filters = ListFilters(type: "core.note", tags: [tag])
            let ascending = try await copy.items.list(filters, sort: Sort(field: .occurredAt, direction: .ascending))
            #expect(ascending.map(\.id) == ids)
            let descending = try await copy.items.list(filters, sort: Sort(field: .occurredAt, direction: .descending))
            #expect(descending.map(\.id) == ids.reversed())

            _ = try await copy.items.transition(ids[0], to: .archived)
            #expect(Set(try await copy.search(word).map(\.item.id)) == Set(ids[1...]))
            #expect(
                Set(try await copy.search(word, filters: SearchFilters(allStates: true)).map(\.item.id)) == Set(ids))
        }

        @Test func aReaderIsToldEachSaveOnceAndWithinASecond() async throws {
            let store = Live.store()
            let writer = try await Live.hydrated(store)
            let reader = try await WorkingCopy.openReader(store: store)
            let heard = Heard(reader.changes())
            var made: [Date] = []
            for save in 1...3 {
                made.append(.now)
                _ = try await writer.items.create(Live.note("saved \(save)"))
                try await Task.sleep(for: .milliseconds(700))
            }
            try await Task.sleep(for: .seconds(1))
            let saves = heard.saves
            #expect(saves.count == 3, "\(heard.all)")
            for (madeAt, told) in zip(made, saves) {
                #expect(
                    told.at.timeIntervalSince(madeAt) < 1, "a save was told \(told.at.timeIntervalSince(madeAt))s late")
            }

            let watch = try #require(reader.feed.watchTask)
            try await bounded("close") { await reader.close() }
            #expect(watch.isCancelled)
            #expect(reader.feed.watchTask == nil)
        }

        /// Rarely races against the real core; `Changes` pins the race down.
        @Test func aSaveMadeAsSoonAsAReaderListensIsTold() async throws {
            let store = Live.store()
            let writer = try await Live.hydrated(store)
            let reader = try await WorkingCopy.openReader(store: store)
            for save in 1...5 {
                let heard = Heard(reader.changes())
                _ = try await writer.items.create(Live.note("at once \(save)"))
                try await eventually("save \(save) was told", within: 1) { !heard.saves.isEmpty }
                heard.stop()
                try await eventually("the stream was let go") { reader.feed.count == 0 }
            }
        }

        /// The core refuses a reader a follow.
        @Test func aSecondOpenerIsToldTheWritersSaves() async throws {
            let store = Live.store()
            let writer = try await Live.hydrated(store)
            let second = try await WorkingCopy.open(store: store, server: Live.server)
            #expect(second.handle == .reader)
            let heard = Heard(second.changes())
            _ = try await writer.items.create(Live.note("seen by the second opener"))
            try await eventually("the second opener was told the writer saved") { !heard.saves.isEmpty }
            #expect(heard.stops.isEmpty)
            try await bounded("close") { await second.close() }
        }

        @Test func aChangeMadeElsewhereArrivesOnTheStream() async throws {
            let watching = try await Live.hydrated()
            let elsewhere = try await Live.hydrated()
            let made = try await elsewhere.items.create(Live.note("from elsewhere"))
            let other = try await elsewhere.items.create(Live.note("linked from elsewhere"))
            let linked = try await elsewhere.edges.create(
                from: try #require(made.itemId), to: try #require(other.itemId), type: "references")
            let heard = Heard(watching.changes())
            _ = try await elsewhere.queue.drain()

            func arrived(_ event: String, where matches: (Change) -> Bool) -> Change? {
                heard.all.first { change in
                    guard case .server(event, _) = change.origin else { return false }
                    return matches(change)
                }
            }
            try await eventually("the note and the edge arrived", within: 20) {
                arrived("item.created") { $0.itemId == made.itemId } != nil
                    && arrived("edge.created") { $0.edgeId == linked.edgeId } != nil
            }
            guard case .server(_, let cursor) = arrived("item.created", where: { $0.itemId == made.itemId })?.origin
            else { return }
            #expect(Int(cursor) != nil, "the change carried the cursor \(cursor)")
            #expect(try await watching.items.get(made.itemId ?? "")?.title == "from elsewhere")

            heard.stop()
            try await eventually("the follow let go of the stream") {
                (try? await watching.holder.run { try $0.catchUp(stop: nil) }) != nil
            }
        }

        /// The core lets go of its stream only as a follow ends, a moment after
        /// it is stopped.
        @Test func aStreamTakenAsSoonAsTheLastIsLetGoIsFed() async throws {
            let watching = try await Live.hydrated()
            let first = Heard(watching.changes())
            // Long enough for the follow to hold the stream.
            try await Task.sleep(for: .milliseconds(300))
            first.stop()
            try await eventually("the first stream was let go") { watching.feed.count == 0 }
            let second = Heard(watching.changes())

            let elsewhere = try await Live.hydrated()
            let made = try await elsewhere.items.create(Live.note("after a stream was let go"))
            _ = try await elsewhere.queue.drain()
            try await eventually("the note arrived on the second stream", within: 20) {
                second.all.contains { $0.itemId == made.itemId }
            }
            #expect(second.stops.isEmpty, "\(second.stops)")
            try await bounded("close") { await watching.close() }
        }

        /// The core refuses a catch-up or hydration while a follow holds the
        /// stream.
        @Test func aCatchUpAndAHydrationRunWhileAStreamIsHeld() async throws {
            let copy = try await Live.hydrated()
            let heard = Heard(copy.changes())
            // Long enough for the follow to hold the stream.
            try await Task.sleep(for: .milliseconds(300))
            _ = try await bounded("the catch-up") { try await copy.catchUp() }
            _ = try await bounded("the hydration") {
                try await copy.hydrate(types: ["core.note", "core.file"], tier: .feed)
            }

            let elsewhere = try await Live.hydrated()
            let made = try await elsewhere.items.create(Live.note("after the hydration"))
            _ = try await elsewhere.queue.drain()
            try await eventually("the follow started again and told the note", within: 20) {
                heard.all.contains { $0.itemId == made.itemId }
            }
            #expect(heard.stops.isEmpty, "\(heard.stops)")
            try await bounded("close") { await copy.close() }
        }

        /// The follow's thread holds the store until the follow ends.
        @Test func closingLetsGoOfTheStore() async throws {
            for _ in 1...5 {
                let store = Live.store()
                try await { () async throws in
                    let copy = try await Live.hydrated(store)
                    let heard = Heard(copy.changes())
                    // Long enough for the follow to hold the stream.
                    try await Task.sleep(for: .milliseconds(300))
                    try await bounded("close") { await copy.close() }
                    withExtendedLifetime(heard) {}
                }()
                #expect(try await WorkingCopy.open(store: store).handle == .writer)
            }
        }
    }

    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveAnswers {
        @Test func aRefusedWriteKeepsItsTypedRefusalAndContentUntilDiscarded() async throws {
            let type = "user.dish\(UUID().uuidString.prefix(8).lowercased())"
            try await Live.writeDefinition([
                "id": type, "fields": ["title": ["type": "string"], "serves": ["type": "string"]],
            ])
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await copy.hydrate(types: [type], tier: .feed)
            let heard = Heard(copy.changes())
            let refused = try await copy.items.create(
                Draft(type: type, properties: ["title": "Too many", "serves": "many"], tier: .feed))
            // A field change preserves the read view, but the server validates
            // queued content against its current schema when it arrives.
            try await Live.writeDefinition(
                ["id": type, "fields": ["title": ["type": "string"], "serves": ["type": "integer"]]],
                at: "types/" + type, method: "PUT")
            let report = try await copy.queue.drain()
            let answer = try #require(report.verdicts.first { $0.id == refused.id })
            guard case .refused(let refusal) = answer.verdict else {
                Issue.record("the write was not refused: \(report.verdicts)")
                return
            }
            #expect(refusal.code == "invalid_properties")
            #expect(refusal.fields.map(\.field) == ["serves"])
            #expect(refusal.fields.first?.message.isEmpty == false)
            #expect(answer.itemId == refused.itemId)
            try await eventually("the drain told which write it answered") {
                heard.all.contains { $0.origin == .answered(answer) && $0.itemId == refused.itemId }
            }

            _ = try await copy.queue.forgetAnswered()
            let kept = try #require(try await copy.queue.all().first { $0.id == refused.id })
            // The type was declared through an unordered dictionary, so its
            // fields' order, and the create's with it, is not fixed here.
            let sent = try #require(kept.body["properties"]?.object, "\(kept.body)")
            #expect(Set(sent.keys) == ["title", "serves"])
            #expect(sent["title"] == "Too many" && sent["serves"] == "many")
            #expect(kept.verdict == .refused(refusal))
            #expect(try await copy.queue.discard(refused.id))
            #expect(try await copy.queue.all().contains { $0.id == refused.id } == false)
            await #expect {
                _ = try await copy.queue.discard(refused.id)
            } throws: { error in
                guard case Marfa.MarfaError.notFound(let code, _) = error else { return false }
                return code == "queued_write_not_found"
            }
            try await bounded("close") { await copy.close() }
        }

        /// An app listens at launch, before its first hydration.
        @Test func aStreamHeldBeforeTheFirstHydrationWaitsForIt() async throws {
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            let heard = Heard(copy.changes())
            try await Task.sleep(for: .milliseconds(300))
            #expect(heard.all.isEmpty, "\(heard.all)")
            _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
            let elsewhere = try await Live.hydrated()
            let made = try await elsewhere.items.create(Live.note("after the first hydration"))
            _ = try await elsewhere.queue.drain()
            try await eventually("the follow started with the hydration", within: 20) {
                heard.all.contains { $0.itemId == made.itemId }
            }
            #expect(heard.stops.isEmpty, "\(heard.stops)")
            try await bounded("close") { await copy.close() }
        }
    }

    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveCatalog {
        /// Each definition's keys in the server's order, whatever order the
        /// fields themselves come in.
        private func expect(
            _ fields: [TypeField], as answered: JSONObject, sourceLocation: SourceLocation = #_sourceLocation
        ) {
            #expect(Set(answered.keys) == Set(fields.map(\.name)), sourceLocation: sourceLocation)
            for field in fields {
                #expect(
                    answered[field.name] == .object(field.definition), "\(field.name)", sourceLocation: sourceLocation)
            }
        }

        @Test func aCustomTypeAndAnEdgeTypeReachTheAppAsTheServerHoldsThem() async throws {
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let dish = "user.dish\(suffix)"
            let recipe = "user.recipe\(suffix)"
            let inspired = "user.inspired-by-\(suffix)"
            try await Live.writeDefinition([
                "id": dish, "label": "Dish",
                "fields": ["serves": ["type": "integer", "description": "How many it feeds", "required": true]],
            ])
            try await Live.writeDefinition([
                "id": recipe, "label": "Recipe", "parent": dish,
                "fields": ["title": ["type": "string"], "method": ["type": "string"]],
                "display_hints": ["title_field": "title", "body_field": "method"],
            ])
            try await Live.writeDefinition(
                [
                    "id": inspired, "label": "Inspired by", "cardinality": "many-to-one",
                    "reverse_name": "user.inspired-\(suffix)", "written_at": "target",
                    "property_schema": ["since": ["type": "string"]],
                ], at: "edge-types")
            let store = Live.store()
            let copy = try await Live.hydrated(store)
            // A reader names no server, so it answers from the store alone.
            let offline = try await WorkingCopy.openReader(store: store)

            for catalog in [copy.catalog, offline.catalog] {
                let type = try await catalog.itemType(recipe)
                #expect(type.label == "Recipe")
                #expect(type.parent == dish)
                #expect(type.titleField == "title")
                #expect(type.bodyField == "method")
                let declaredBy = Dictionary(uniqueKeysWithValues: type.fields.map { ($0.name, $0.declaredBy) })
                #expect(declaredBy == ["serves": dish, "title": recipe, "method": recipe])
                let serves = try #require(type.fields.first { $0.name == "serves" })
                #expect(serves.type == "integer")
                #expect(serves.required)
                #expect(serves.description == "How many it feeds")

                let answered = try await Live.read("types/\(recipe)")
                guard case .object(let fields) = answered["fields"] else {
                    Issue.record("the server answered no fields for \(recipe): \(answered)")
                    return
                }
                #expect(answered["label"] == .string("Recipe"))
                #expect(answered["parent"] == .string(dish))
                expect(type.fields, as: fields)

                let listed = try await catalog.itemTypes()
                #expect(listed.map(\.id) == listed.map(\.id).sorted())
                #expect(listed.first { $0.id == recipe } == type)
                #expect(listed.contains { $0.id == dish })
                #expect(listed.contains { $0.id == "core.note" })

                let edgeType = try await catalog.edgeType(inspired)
                let server = try #require(try await Live.edgeTypes()[inspired])
                #expect(edgeType.reverseName == "user.inspired-\(suffix)")
                #expect(server["reverse_name"] == .string("user.inspired-\(suffix)"))
                #expect(edgeType.writtenAt == .target)
                #expect(server["written_at"] == "target")
                #expect(edgeType.label == "Inspired by")
                #expect(server["cardinality"] == .string(edgeType.cardinality))
                #expect(server["cascade_on_delete"] == .string(edgeType.cascadeOnDelete))
                #expect(
                    server["source_type_constraints"] == .array(edgeType.sourceTypeConstraints.map(JSONValue.string)))
                #expect(
                    server["target_type_constraints"] == .array(edgeType.targetTypeConstraints.map(JSONValue.string)))
                #expect(server["shipped"] == .bool(edgeType.shipped))
                #expect(!edgeType.shipped)
                expect(edgeType.properties, as: server["property_schema"]?.object ?? [:])
                #expect(edgeType.properties.map(\.declaredBy) == [inspired])
                let edgeTypes = try await catalog.edgeTypes()
                #expect(edgeTypes.contains { $0.id == inspired })
                #expect(edgeTypes.contains { $0.id == "references" && $0.shipped })
            }

            await #expect {
                _ = try await copy.catalog.itemType("user.never\(suffix)")
            } throws: { error in
                guard case Marfa.MarfaError.notFound(let code, _) = error else { return false }
                return code == "type_not_found"
            }
            await #expect {
                _ = try await copy.catalog.edgeType("user.never-\(suffix)")
            } throws: { error in
                guard case Marfa.MarfaError.notFound(let code, _) = error else { return false }
                return code == "edge_type_not_found"
            }
        }

        @Test func aCopyWithAServerReadsBuiltInsBeforeItsFirstHydration() async throws {
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            #expect(try await copy.status().catalogVersion == nil)
            #expect(try await copy.catalog.itemTypes().contains { $0.id == "core.note" })
            #expect(try await copy.catalog.edgeTypes().contains { $0.id == "references" })
            _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
            #expect(try await copy.status().catalogVersion != nil)
            #expect(try await !copy.catalog.itemTypes().isEmpty)
            #expect(try await !copy.catalog.edgeTypes().isEmpty)
            await copy.close()
        }

        @Test func aNewTypeExpiresTheViewAndRehydrationKeepsQueuedContent() async throws {
            let copy = try await Live.hydrated()
            let before = try #require(try await copy.status().catalogVersion)
            let queued = try await copy.items.create(Live.note("Kept"))
            let late = "user.late\(UUID().uuidString.prefix(8).lowercased())"
            try await Live.writeDefinition(["id": late, "label": "Late", "fields": ["title": ["type": "string"]]])
            await #expect { try await copy.catchUp() } throws: { error in
                if case MarfaError.copyExpired(let reason, _) = error { reason == "read_view_changed" } else { false }
            }
            let waiting = try #require(try await copy.queue.all().first { $0.id == queued.id })
            #expect(waiting.idempotencyKey == queued.idempotencyKey)
            #expect(waiting.body == queued.body)
            let heard = Heard(copy.changes())
            _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
            try await eventually("the rebuilt catalog was told", within: 10) {
                heard.all.contains(Change(origin: .refreshed(.hydrated), itemId: nil, edgeId: nil))
            }
            let after = try #require(try await copy.status().catalogVersion)
            #expect(after > before)
            #expect(try await copy.catalog.itemType(late).label == "Late")
            let itemId = try #require(queued.itemId)
            #expect(try await copy.items.get(itemId)?.properties["title"] == "Kept")
            try await bounded("close") { await copy.close() }
        }

        @Test func aLabelChangeRefreshesTheCatalogWithoutExpiringTheView() async throws {
            let type = "user.label\(UUID().uuidString.prefix(8).lowercased())"
            try await Live.writeDefinition(["id": type, "label": "Before", "fields": ["title": ["type": "string"]]])
            let copy = try await Live.hydrated()
            let before = try #require(try await copy.status().catalogVersion)
            let heard = Heard(copy.changes())
            try await Live.writeDefinition(
                ["id": type, "label": "After", "fields": ["title": ["type": "string"]]],
                at: "types/\(type)", method: "PUT")
            _ = try await copy.catchUp()
            try await eventually("the catalog label change was told", within: 10) {
                heard.all.contains(Change(origin: .refreshed(.catalog), itemId: nil, edgeId: nil))
            }
            #expect(try await copy.catalog.itemType(type).label == "After")
            let after = try #require(try await copy.status().catalogVersion)
            #expect(after > before)
            try await bounded("close") { await copy.close() }
        }
    }
}

extension Server {
    func with(key: String) -> Server { Server(url: url, key: key) }
}
