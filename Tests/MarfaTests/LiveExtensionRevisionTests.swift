import Foundation
import MarfaAPI
import Testing

@testable import Marfa

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(1)))
    struct LiveExtensionRevision {
        static let namespace = "swiftguard"

        /// The namespace as the generated client reads it, so the test holds what an app reads.
        static func read(_ id: String) async throws -> (document: [String: Bool], revision: String) {
            let api = Client(try #require(Live.server))
            let answer = try await api.getItemExtension(path: .init(id: id, namespace: namespace)).ok.body.json
            let document = answer.document?.additionalProperties.compactMapValues { $0.value as? Bool }
            return (document ?? [:], answer.revision)
        }

        /// Another writer's `PUT` or `DELETE`, which the copy under test never sees queued.
        static func elsewhere(_ id: String, method: String, body: String? = nil) async throws {
            let server = try #require(Live.server)
            var request = URLRequest(url: server.url.appending(path: "items/\(id)/extensions/\(namespace)"))
            request.httpMethod = method
            request.setValue("Bearer \(server.key)", forHTTPHeaderField: "Authorization")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(body.utf8)
            }
            let (answer, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            try #require(status == 200, "\(method) answered \(status ?? 0): \(String(decoding: answer, as: UTF8.self))")
        }

        static func verdict(_ copy: WorkingCopy, of write: QueuedWrite) async throws -> QueuedWrite {
            let report = try await copy.queue.drain()
            #expect(report.verdicts.count == 1, "\(report.verdicts)")
            return try #require(try await copy.queue.all().first { $0.id == write.id })
        }

        @Test func aGuardedWriteLandsOnTheRevisionReadAndIsBlockedOnceAnotherWriterMovedTheNamespace() async throws {
            let copy = try await Live.hydrated()
            let id = try #require(try await copy.items.create(Live.note("guarded \(UUID())")).itemId)
            _ = try await copy.queue.drain()

            let absent = try await Self.read(id)
            #expect(absent.document.isEmpty, "the witness: the namespace is empty before the first write")
            let created = try await copy.extensions.write(
                Self.namespace, ["mine": true], on: id, readRevision: absent.revision)
            #expect(try await Self.verdict(copy, of: created).verdict == .accepted)
            let mine = try await Self.read(id)
            #expect(mine.document == ["mine": true] && mine.revision != absent.revision)

            try await Self.elsewhere(id, method: "PUT", body: #"{"theirs":true}"#)
            let theirs = try await Self.read(id)
            #expect(theirs.revision != mine.revision)

            let stale = try await copy.extensions.write(
                Self.namespace, ["mine": false], on: id, readRevision: mine.revision)
            let blocked = try await Self.verdict(copy, of: stale)
            #expect(blocked.verdict == .blocked(reason: .conflictUnresolved), "\(String(describing: blocked.verdict))")
            #expect(blocked.body == ["mine": false], "the person's value stayed in the queue")
            #expect(try await Self.read(id).document == ["theirs": true], "a blocked write changed the namespace")

            #expect(try await copy.queue.release(stale.id))
            #expect(try await Self.verdict(copy, of: stale).verdict == .accepted)
            #expect(
                try await Self.read(id).document == ["mine": false],
                "a released write goes over the namespace as it stands")
            await copy.close()
        }

        @Test func aGuardedDeleteGoesOnTheRevisionReadAndIsBlockedOnceAnotherWriterMovedTheNamespace() async throws {
            let copy = try await Live.hydrated()
            let id = try #require(try await copy.items.create(Live.note("guarded delete \(UUID())")).itemId)
            _ = try await copy.queue.drain()
            try await Self.elsewhere(id, method: "PUT", body: #"{"first":true}"#)

            let read = try await Self.read(id)
            let removal = try await copy.extensions.delete(Self.namespace, from: id, readRevision: read.revision)
            #expect(try await Self.verdict(copy, of: removal).verdict == .accepted)
            #expect(try await Self.read(id).document.isEmpty, "the delete on the revision read did not remove it")

            try await Self.elsewhere(id, method: "PUT", body: #"{"second":true}"#)
            let moved = try await Self.read(id)
            let stale = try await copy.extensions.delete(Self.namespace, from: id, readRevision: read.revision)
            let blocked = try await Self.verdict(copy, of: stale)
            #expect(blocked.verdict == .blocked(reason: .conflictUnresolved), "\(String(describing: blocked.verdict))")
            #expect(try await Self.read(id).revision == moved.revision, "a blocked delete changed the namespace")
            await copy.close()
        }

        @Test func aWriteWithNoRevisionReplacesTheNamespaceAsItStands() async throws {
            let copy = try await Live.hydrated()
            let id = try #require(try await copy.items.create(Live.note("unguarded \(UUID())")).itemId)
            _ = try await copy.queue.drain()
            try await Self.elsewhere(id, method: "PUT", body: #"{"theirs":true}"#)

            let write = try await copy.extensions.write(Self.namespace, ["mine": true], on: id)

            #expect(try await Self.verdict(copy, of: write).verdict == .accepted)
            #expect(try await Self.read(id).document == ["mine": true])
            await copy.close()
        }
    }
}
