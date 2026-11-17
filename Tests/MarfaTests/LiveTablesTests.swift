import Foundation
import Testing

@testable import Marfa

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(3)))
    struct LiveTables {
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

        private func mintKey(for type: String, suffix: String) async throws -> (id: String, server: Server) {
            let minted = try await request(
                "POST", "keys",
                body: [
                    "label": "Swift tables test", "source": "swift-\(suffix)", "default_tier": "library",
                    "type_permissions": [type: "write"], "metadata_permissions": ["types": "write", "tags": "write"],
                ])
            return (
                try #require(minted["id"]?.string),
                Server(url: try #require(Live.server).url, key: try #require(minted["key"]?.string))
            )
        }

        private func definition(_ type: String) -> JSONObject {
            [
                "id": .string(type), "fields": ["title": ["type": "string", "required": true]],
                "tables": ["steps": ["columns": ["count": ["type": "integer"], "note": ["type": "string"]]]],
            ]
        }

        private func row(_ suffix: String) -> String {
            "019a0000-0000-7000-8000-\(suffix)"
        }

        /// A copy that holds one item of a type declaring the table `steps`, with the table held whole.
        private func copyHoldingSteps(_ server: Server, type: String, item: String?) async throws -> (
            WorkingCopy, String
        ) {
            let copy = try await WorkingCopy.open(store: Live.store(), server: server)
            try await copy.declareTypes([definition(type)])
            var itemId = item
            if itemId == nil {
                let made = try await copy.items.create(
                    Draft(type: type, properties: ["title": "Steps"], tier: .library))
                itemId = made.itemId
            }
            let hydrated = try await copy.hydrate(types: [type], tier: .library)
            #expect(hydrated.unregisteredTypes.isEmpty)
            if item == nil {
                let drained = try await copy.queue.drain()
                #expect(drained.verdicts.allSatisfy { $0.verdict == .accepted }, "\(drained)")
                _ = try await copy.queue.forgetAnswered()
            }
            return (copy, try #require(itemId))
        }

        @Test func aTableIsHeldFilledReadWrittenAndUndone() async throws {
            let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let type = "app.swift\(suffix).steps"
            let minted = try await mintKey(for: type, suffix: suffix)
            let (copy, item) = try await copyHoldingSteps(minted.server, type: type, item: nil)
            let first = row("0000000000a1")
            do {
                // Before the hold, the server answers a read, and says so.
                let asked = try await copy.tables.rows(of: item, in: "steps")
                #expect(!asked.held && asked.value.rows.isEmpty)

                let hold = try await copy.tables.hold("steps", ofType: type)
                #expect(!hold.wasHeld)
                #expect(hold.fill?.whole == 1, "\(hold)")
                let held = try await copy.tables.held()
                #expect(held.choices == [TableChoice(type: type, table: "steps")])
                #expect(held.tables == [HeldTable(itemId: item, table: "steps", state: .whole, rows: 0)])
                #expect(try await copy.tables.hold("steps", ofType: type).wasHeld)

                let written = try await copy.tables.write(
                    [.put(id: first, values: ["count": 2, "note": "first"])], to: "steps", of: item)
                #expect(written.kind == .writeRows && written.verdict == nil)

                // Shown at once, from the copy, with the server not asked.
                let shown = try await copy.tables.rows(of: item, in: "steps")
                #expect(shown.held)
                #expect(shown.value.rows.map(\.id) == [first])
                #expect(shown.value.rows.first?.values["note"] == "first")
                let one = try await copy.tables.row(first, of: item, in: "steps")
                #expect(one.held && one.value.values["count"] == 2)
                let totals = try await copy.tables.totals(of: item, in: "steps")
                #expect(totals.held && totals.value.rowCount == 1)

                let drained = try await copy.queue.drain()
                #expect(drained.verdicts.first { $0.id == written.id }?.verdict == .accepted, "\(drained)")
                let answered = try #require(try await copy.queue.all().first { $0.id == written.id })
                let batch = try #require(answered.rowBatch, "\(String(describing: answered.answer))")

                let sorted = try await copy.tables.rows(
                    of: item, in: "steps", RowsQuery(limit: 10, sort: .column("count"), direction: .descending))
                #expect(sorted.held && sorted.value.rows.map(\.id) == [first] && sorted.value.nextCursor == nil)

                let undone = try await copy.tables.undo(batch: batch, in: "steps", of: item)
                #expect(undone.kind == .undoRows)
                let undoDrained = try await copy.queue.drain()
                #expect(undoDrained.verdicts.first { $0.id == undone.id }?.verdict == .accepted, "\(undoDrained)")
                _ = try await copy.catchUp()
                try await eventually("the undo's row change arrives") {
                    try await copy.tables.rows(of: item, in: "steps").value.rows.isEmpty
                }

                #expect(try await copy.tables.letGo("steps", ofType: type))
                #expect(try await copy.tables.held() == HeldTables())
                #expect(!(try await copy.tables.rows(of: item, in: "steps").held))
                await copy.close()
                _ = try await request("DELETE", "keys/\(minted.id)")
            } catch {
                await copy.close()
                _ = try? await request("DELETE", "keys/\(minted.id)")
                throw error
            }
        }

        @Test func aPutWithNoIdIsGivenOneAndShownAtOnce() async throws {
            let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let type = "app.swift\(suffix).steps"
            let minted = try await mintKey(for: type, suffix: suffix)
            let (copy, item) = try await copyHoldingSteps(minted.server, type: type, item: nil)
            do {
                _ = try await copy.tables.hold("steps", ofType: type)
                let written = try await copy.tables.write([.put(values: ["note": "anonymous"])], to: "steps", of: item)
                let shown = try await copy.tables.rows(of: item, in: "steps")
                #expect(shown.value.rows.count == 1 && shown.value.rows.first?.values["note"] == "anonymous")
                let drained = try await copy.queue.drain()
                #expect(drained.verdicts.first { $0.id == written.id }?.verdict == .accepted, "\(drained)")
                #expect(try await copy.tables.rows(of: item, in: "steps").value.rows.count == 1)
                await copy.close()
                _ = try await request("DELETE", "keys/\(minted.id)")
            } catch {
                await copy.close()
                _ = try? await request("DELETE", "keys/\(minted.id)")
                throw error
            }
        }

        @Test func aWriteThatReplacesACellAnotherWriterSetIsConflictedAndNamesIt() async throws {
            let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let type = "app.swift\(suffix).steps"
            let minted = try await mintKey(for: type, suffix: suffix)
            let (mine, item) = try await copyHoldingSteps(minted.server, type: type, item: nil)
            let (theirs, _) = try await copyHoldingSteps(minted.server, type: type, item: item)
            let shared = row("0000000000b2")
            do {
                _ = try await mine.tables.hold("steps", ofType: type)
                _ = try await theirs.tables.hold("steps", ofType: type)
                _ = try await mine.tables.write(
                    [.put(id: shared, values: ["count": 1, "note": "start"])], to: "steps", of: item)
                _ = try await mine.queue.drain()
                _ = try await theirs.catchUp()
                #expect(try await theirs.tables.row(shared, of: item, in: "steps").value.values["count"] == 1)

                // Another writer sets the cell, and this copy has not heard of it when its own write is made.
                _ = try await theirs.tables.write([.patch(id: shared, values: ["count": 5])], to: "steps", of: item)
                let theirAnswer = try await theirs.queue.drain()
                #expect(theirAnswer.verdicts.allSatisfy { $0.verdict == .accepted }, "\(theirAnswer)")

                let replacing = try await mine.tables.write(
                    [.patch(id: shared, values: ["count": 9])], to: "steps", of: item)
                let answer = try await mine.queue.drain()
                let verdict = try #require(answer.verdicts.first { $0.id == replacing.id }?.verdict, "\(answer)")
                guard case .conflicted(nil, _, let conflicts) = verdict else {
                    Issue.record("expected a row conflict, got \(verdict)")
                    throw CancellationError()
                }
                #expect(conflicts == [RowConflict(row: shared, column: "count")])

                await mine.close()
                await theirs.close()
                _ = try await request("DELETE", "keys/\(minted.id)")
            } catch {
                await mine.close()
                await theirs.close()
                _ = try? await request("DELETE", "keys/\(minted.id)")
                throw error
            }
        }
    }
}
