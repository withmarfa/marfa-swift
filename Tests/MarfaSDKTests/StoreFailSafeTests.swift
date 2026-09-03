import Testing
import Foundation
import SwiftData
@testable import MarfaSDK
@_spi(MarfaSDKTestSupport) import MarfaSDK
@testable import MarfaSDKTestSupport

/// What happens to a store this build cannot use.
///
/// The four things checked here exist nowhere but the device: a queued write,
/// the log of one the server refused, the bytes behind a queued upload, and
/// the cursor saying which events this device has already seen. Everything
/// else in the store comes back from the next import.
@Suite("A store the current schema cannot open")
struct StoreFailSafeTests {

    // MARK: - Stores no version describes

    /// A copy of the edge model carrying one column the real one does not.
    ///
    /// Enough to make a whole store unopenable: Core Data hashes each entity
    /// independently and refuses the store when any one of them matches no
    /// version in the plan. The edge model is the copy because it has no
    /// relationships to drag along and because nothing salvaged out of the
    /// store comes from it — so the four tables that are salvaged keep exactly
    /// the shape a real build writes.
    enum Alien {
        @Model
        final class MarfaEdgeModel {
            var id: String = ""
            var sourceId: String = ""
            var targetId: String = ""
            var edgeType: String = ""
            var propertiesData: Data = Data("{}".utf8)
            var spaceId: String?
            var createdAt: String = ""
            var updatedAt: String = ""
            var aColumnNoShippedBuildEverWrote: String?

            init() {}
        }

        /// Every live model except the edge, plus the alien one.
        static var models: [any PersistentModel.Type] {
            MarfaSchemaV3.models.filter { String(describing: $0) != "MarfaEdgeModel" }
                + [MarfaEdgeModel.self]
        }
    }

    /// A versioned schema stamped further ahead than this build knows, over
    /// the models this build compiles.
    ///
    /// Deliberately openable: the hashes match V3 exactly, so nothing but the
    /// recorded version number stands between the container and the store.
    /// That is what makes it a test of the refusal rather than of the hashes.
    enum SchemaFromTheFuture: VersionedSchema {
        static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }
        static var models: [any PersistentModel.Type] { MarfaSchemaV3.models }
    }

    // MARK: - Fixtures

    private static let queuedId = "019eb100-0000-7000-8000-0000000000b1"
    private static let queuedLocalId = "019eb100-0000-7000-8000-0000000000b2"
    private static let deadLetterId = "019eb100-0000-7000-8000-0000000000b3"
    private static let cursorValue = "evt-2048"
    private static let blobHash = "sha256:decafbad"

    private func makeDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("marfa-failsafe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes a store at `path` through `models`, seeded with the rows only a
    /// device holds. Scoped so the container is released and the store
    /// checkpointed before anything else touches the file.
    private func seedStore(
        at path: String,
        models: [any PersistentModel.Type],
        version: (any VersionedSchema.Type)? = nil
    ) throws {
        let schema = version.map { Schema(versionedSchema: $0) } ?? Schema(models)
        let container = try MarfaModelContainer.withCreationLock {
            try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(
                    "marfa",
                    schema: schema,
                    url: URL(fileURLWithPath: path),
                    allowsSave: true,
                    cloudKitDatabase: .none
                )
            )
        }
        let context = ModelContext(container)
        let stamp = "2026-09-03T09:00:00.000Z"

        let queued = PendingMutationModel()
        queued.id = Self.queuedId
        queued.kindRaw = MutationKind.updateItem.rawValue
        queued.payloadJson = #"{"id":"\#(Self.queuedLocalId)","properties":{"body":"typed on a plane"}}"#
        queued.localId = Self.queuedLocalId
        queued.createdAt = stamp
        queued.attemptCount = 3
        queued.stateRaw = PendingMutationState.pending.rawValue
        context.insert(queued)

        let deadLetter = DroppedMutationModel()
        deadLetter.id = Self.deadLetterId
        deadLetter.kindRaw = MutationKind.deleteItem.rawValue
        deadLetter.payloadJson = #"{"id":"gone"}"#
        deadLetter.enqueuedAt = stamp
        deadLetter.droppedAt = stamp
        deadLetter.attemptCount = 1
        deadLetter.errorStatus = 404
        deadLetter.errorCode = "not_found"
        deadLetter.errorMessage = "gone"
        context.insert(deadLetter)

        let cursor = SyncStateModel()
        cursor.key = "last_event_id"
        cursor.value = Self.cursorValue
        context.insert(cursor)

        let blob = PendingBlobModel()
        blob.contentHash = Self.blobHash
        blob.data = Data([0x89, 0x50, 0x4E, 0x47])
        blob.mimeType = "image/png"
        context.insert(blob)

        try context.save()
    }

    private func sidecar(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "the sidecar is not a JSON object"
        )
    }

    private func rows(_ sidecar: [String: Any], _ key: String) -> [[String: Any]] {
        sidecar[key] as? [[String: Any]] ?? []
    }

    // MARK: - Tests

    @Test("a store this build cannot open is moved aside, not deleted")
    func unopenableStoreIsQuarantined() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path
        try seedStore(at: path, models: Alien.models)
        // The inode, because it is the one thing a rename preserves and a
        // delete-and-recreate cannot fake. File size would not do: the salvage
        // read checkpoints the store's write-ahead log, so the bytes move for
        // an innocent reason.
        let inodeBefore = try #require(
            try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int
        )

        let opened = try MarfaModelContainer.open(path: path)
        let recovery = try #require(
            opened.recovery,
            "the container opened a store whose shape matches no schema version"
        )
        #expect(recovery.cause == .unreadable)

        // The old store is the same file, in a directory of its own, with its
        // rows. Deleting it is what this change exists to stop.
        let quarantined = recovery.quarantineDirectory.appendingPathComponent("store.sqlite")
        #expect(
            (try FileManager.default.attributesOfItem(atPath: quarantined.path)[.systemFileNumber] as? Int)
                == inodeBefore
        )
        let salvage = try QuarantinedStoreReader.read(storeAt: quarantined)
        #expect(salvage.rows("pendingMutations").count == 1)
        #expect(salvage.rows("droppedMutations").count == 1)

        // And the app has a working store to carry on with.
        #expect(try ModelContext(opened.container).fetch(FetchDescriptor<PendingMutationModel>()).isEmpty)
    }

    @Test("the queued writes, the dead letters and the cursor are written out where an app can read them")
    func theQueueIsSalvagedIntoASidecar() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path
        try seedStore(at: path, models: Alien.models)

        let recovery = try #require(try MarfaModelContainer.open(path: path).recovery)
        #expect(recovery.sidecarError == nil)
        #expect(recovery.pendingMutationCount == 1)
        #expect(recovery.droppedMutationCount == 1)
        #expect(recovery.pendingBlobCount == 1)
        #expect(recovery.cursor == Self.cursorValue)

        let file = try #require(recovery.sidecar, "no sidecar was written")
        let sidecar = try self.sidecar(at: file)
        #expect(sidecar["format"] as? Int == 1)

        // The payload, not just the count. A queued write whose body did not
        // survive is a row an app can list and cannot act on.
        let queued = try #require(rows(sidecar, "pendingMutations").first)
        #expect(queued["id"] as? String == Self.queuedId)
        #expect(queued["localId"] as? String == Self.queuedLocalId)
        #expect(queued["kindRaw"] as? String == MutationKind.updateItem.rawValue)
        #expect(queued["attemptCount"] as? Int == 3)
        #expect((queued["payloadJson"] as? String)?.contains("typed on a plane") == true)

        let deadLetter = try #require(rows(sidecar, "droppedMutations").first)
        #expect(deadLetter["id"] as? String == Self.deadLetterId)
        #expect(deadLetter["errorStatus"] as? Int == 404)
        #expect(deadLetter["errorCode"] as? String == "not_found")

        #expect(rows(sidecar, "syncState").first?["value"] as? String == Self.cursorValue)

        // A blob's descriptor travels; its bytes stay in the quarantined store
        // rather than being inlined into a text file.
        let blob = try #require(rows(sidecar, "pendingBlobs").first)
        #expect(blob["contentHash"] as? String == Self.blobHash)
        #expect(blob["mimeType"] as? String == "image/png")
    }

    @Test("a store that cannot be moved aside is not wiped either")
    func noQuarantineMeansNoWipe() throws {
        let directory = makeDirectory()
        let path = directory.appendingPathComponent("store.sqlite").path
        try seedStore(at: path, models: Alien.models)

        // Read and execute only: the store can still be read, and nothing new
        // can be created beside it — so the quarantine directory cannot be
        // made and the rename has nowhere to go.
        let fileManager = FileManager.default
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? fileManager.removeItem(at: directory)
        }

        #expect(throws: LocalStoreError.self) {
            _ = try MarfaModelContainer.open(path: path)
        }

        // The store is still there, and still holds what it held. The failure
        // this refuses to perform silently is the one that would have taken
        // the queue with it.
        #expect(fileManager.fileExists(atPath: path))
        let salvage = try QuarantinedStoreReader.read(storeAt: URL(fileURLWithPath: path))
        #expect(salvage.rows("pendingMutations").count == 1)
        #expect(salvage.rows("droppedMutations").count == 1)
    }

    @Test("a store written by a newer build is refused rather than opened")
    func aStoreFromTheFutureIsRefused() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path
        // Current shapes, so nothing but the recorded version number can
        // refuse it.
        try seedStore(at: path, models: MarfaSchemaV3.models, version: SchemaFromTheFuture.self)

        let recovery = try #require(
            try MarfaModelContainer.open(path: path).recovery,
            "a store stamped 4.0.0 was opened by a build that knows up to 3.0.0"
        )
        #expect(recovery.cause == .newerThanCode)
        #expect(recovery.reason.contains("4.0.0"))
        #expect(recovery.pendingMutationCount == 1)
        #expect(FileManager.default.fileExists(
            atPath: recovery.quarantineDirectory.appendingPathComponent("store.sqlite").path
        ))
    }

    @Test("a store that has never existed is not a recovery")
    func aMissingStoreIsNotARecovery() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path

        // The ordinary first launch. Nothing was set aside and nothing is
        // reported — a fresh install that announced a recovery would send
        // every new user looking for a directory that does not exist.
        let opened = try MarfaModelContainer.open(path: path)
        #expect(opened.recovery == nil)
        #expect(try ModelContext(opened.container).fetch(FetchDescriptor<PendingMutationModel>()).isEmpty)
    }

    @Test("an open that fails with no store there reports why, rather than blaming the quarantine")
    func aFailedOpenWithNoStoreKeepsItsOwnError() throws {
        // A directory nothing can be created in, and no store in it. The
        // container fails, and there is nothing to move aside — so the
        // recovery path must not run and claim the quarantine was the problem.
        // Reaching for a quarantine here would replace the one error that says
        // what is wrong with one that says a file could not be moved, about a
        // file that was never there.
        let directory = makeDirectory()
        let fileManager = FileManager.default
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? fileManager.removeItem(at: directory)
        }
        let path = directory.appendingPathComponent("store.sqlite").path

        do {
            _ = try MarfaModelContainer.open(path: path)
            Issue.record("the open succeeded in a directory nothing can be written to")
        } catch let error as LocalStoreError {
            if case .storeQuarantineFailed(let message) = error {
                Issue.record("the open blamed the quarantine for a store that was never there: \(message)")
            }
        } catch {
            // Any other error is the container's own, which is the point.
        }
    }

    // MARK: - Telling the app

    @Test("the app is told, on the events stream, that its store was rebuilt")
    func theAppIsToldThroughTheEventStream() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path
        try seedStore(at: path, models: Alien.models)

        let opened = try MarfaModelContainer.open(path: path)
        let recovery = try #require(opened.recovery)

        let container = opened.container
        let store = await Task.detached { LocalStore(modelContainer: container) }.value
        let queue = await Task.detached { MutationQueue(modelContainer: container) }.value
        try await SyncEngineTestKit.markImported(queue)
        let engine = SyncEngine(
            transport: MockTransport(),
            localStore: store,
            mutationQueue: queue,
            connectionManager: ConnectionStateManager(),
            storeRecovery: recovery
        )

        // Subscribing before `start()` is the documented order, and the
        // announcement has to survive it: the store was opened long before an
        // engine existed to say so.
        let stream = engine.events
        await engine.start()
        let published = await SyncEngineTestKit.publishedEvents(from: stream, closing: engine)

        let announced = published.compactMap { event -> StoreRecovery? in
            if case .storeRecovered(let payload) = event { return payload }
            return nil
        }
        #expect(announced == [recovery])
    }

    @Test("a pure-local client, which has no engine, can still be asked")
    func aLocalClientCarriesTheRecovery() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path
        try seedStore(at: path, models: Alien.models)

        let client = try await MarfaClient.local(path: path)
        let recovery = try #require(
            client.storeRecovery,
            "the client rebuilt its store and said nothing about it"
        )
        #expect(recovery.pendingMutationCount == 1)
        #expect(recovery.cursor == Self.cursorValue)
    }
}
