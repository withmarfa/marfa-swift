import Testing
import Foundation
import SwiftData
@testable import MarfaSDK
@_spi(MarfaSDKTestSupport) import MarfaSDK
@testable import MarfaSDKTestSupport

/// Performs every rename but one.
///
/// The branch under test is only reachable this way. On a real filesystem
/// anything that stops a rename — a permission, a lock, an immutable flag —
/// stops the removal beside it as well, so a store obstructed into failing the
/// move would survive the deletion too and the test would pass against the
/// defect. A full disk is what separates the two: a rename needs a new
/// directory entry and an unlink does not.
private final class RefusesOneMove: FileManager {
    private let refused: String

    init(refusing name: String) {
        self.refused = name
        super.init()
    }

    override func moveItem(at source: URL, to destination: URL) throws {
        guard source.lastPathComponent != refused else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try super.moveItem(at: source, to: destination)
    }
}

/// Seals the store's own directory the moment the store has left it.
///
/// That is the window this pins: the quarantine has succeeded, so the old
/// store and everything only it held are safe, and the fresh store that should
/// replace them cannot be created.
private final class SealsAfterMovingTheStore: FileManager {
    private let store: String

    init(sealingAfter store: String) {
        self.store = store
        super.init()
    }

    override func moveItem(at source: URL, to destination: URL) throws {
        try super.moveItem(at: source, to: destination)
        guard source.lastPathComponent == store else { return }
        try super.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: source.deletingLastPathComponent().path
        )
    }
}

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
        version: (any VersionedSchema.Type)? = nil,
        blob: Data = Data([0x89, 0x50, 0x4E, 0x47])
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

        let pendingBlob = PendingBlobModel()
        pendingBlob.contentHash = Self.blobHash
        pendingBlob.data = blob
        pendingBlob.mimeType = "image/png"
        context.insert(pendingBlob)

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

    /// The support directory is where the bytes are, and it is the one sibling
    /// a fresh store can live beside.
    ///
    /// Core Data writes an externally stored attribute to a file under
    /// `.<store>_SUPPORT/_EXTERNAL_DATA/`, named with a fresh UUID, and for
    /// this schema that attribute is the payload of every queued blob upload.
    /// A journal that will not move is removed because nothing can ever
    /// replay what it holds; applying the same rule here would delete the only
    /// copy of that payload, which is the loss the whole quarantine exists to
    /// prevent.
    @Test("a support directory that will not move is left alone, not deleted with the journals")
    func anUnmovableSupportDirectorySurvives() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path
        // A megabyte, because the threshold is what decides whether there is
        // anything to lose: 128 KB stays in the row and 256 KB does not, so
        // every other fixture in this suite produces an empty support
        // directory and could not fail this test however it were written.
        let payload = Data(repeating: 0x5A, count: 1 << 20)
        try seedStore(at: path, models: Alien.models, blob: payload)

        let external = directory
            .appendingPathComponent(".store_SUPPORT")
            .appendingPathComponent("_EXTERNAL_DATA")
        let name = try #require(
            try FileManager.default.contentsOfDirectory(atPath: external.path).first,
            "the fixture stored nothing outside store.sqlite, so there is nothing here to lose"
        )
        let blobFile = external.appendingPathComponent(name)
        #expect(try Data(contentsOf: blobFile) == payload)

        let opened = try MarfaModelContainer.open(
            path: path,
            fileManager: RefusesOneMove(refusing: ".store_SUPPORT")
        )
        let recovery = try #require(opened.recovery)
        #expect(recovery.cause == .unreadable)

        // Still there, still the same bytes, at the path it was always at.
        #expect(
            FileManager.default.fileExists(atPath: blobFile.path),
            "the queued upload's bytes were deleted by the path written to preserve them"
        )
        #expect((try? Data(contentsOf: blobFile)) == payload)

        // And the fresh store is untroubled by inheriting them, which is the
        // other half of why they may be left where they are.
        #expect(try ModelContext(opened.container).fetch(FetchDescriptor<PendingBlobModel>()).isEmpty)
    }

    /// The salvage reads until `sqlite3_step` stops returning rows, and a
    /// damaged page stops it exactly the way the end of the table does.
    ///
    /// Both arrive as "no more rows", so a read that hit `SQLITE_CORRUPT`
    /// half-way through a table produces a shorter list and nothing else — no
    /// error, no warning, and a count an app will show to a person as the
    /// number of unsent changes. The store is set aside for a shape this build
    /// has no model for, which says nothing about the bytes; but the same path
    /// takes a store that really is damaged, and that is where this bites.
    @Test("a salvage that stops part-way through a table says so instead of reporting a total")
    func aTruncatedSalvageIsNotReportedAsComplete() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("store.sqlite")

        // Four hundred rows with fat payloads, so the table is most of the
        // file and damage to the back of it lands in the middle of the table.
        let schema = Schema(Alien.models)
        do {
            let container = try MarfaModelContainer.withCreationLock {
                try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(
                        "marfa",
                        schema: schema,
                        url: store,
                        allowsSave: true,
                        cloudKitDatabase: .none
                    )
                )
            }
            let context = ModelContext(container)
            for index in 0..<400 {
                let queued = PendingMutationModel()
                queued.id = "019eb100-0000-7000-8000-\(String(format: "%012d", index))"
                queued.kindRaw = MutationKind.updateItem.rawValue
                queued.payloadJson = String(repeating: "x", count: 900)
                queued.createdAt = "2026-09-03T09:00:00.000Z"
                context.insert(queued)
            }
            try context.save()
        }
        for journal in ["store.sqlite-wal", "store.sqlite-shm"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(journal))
        }
        // The store file alone holds all four hundred, so corrupting it
        // corrupts what the salvage will read. This also fails loudly if the
        // release above stopped checkpointing.
        #expect(try QuarantinedStoreReader.read(storeAt: store).rows("pendingMutations").count == 400)

        // The last two fifths of the file, which is a stretch of the table
        // rather than one page of it. A single corrupted page leaves the
        // outcome to where SQLite happened to put that page: measured over ten
        // runs it read the whole table twice, because the file is not the same
        // size twice. Truncating the file instead is no good either — the
        // read then fails at `prepare` and never reaches the loop this is
        // about, which is a case `sidecarError` already covers.
        var bytes = try Data(contentsOf: store)
        for offset in ((bytes.count * 3) / 5)..<bytes.count { bytes[offset] = 0xFF }
        try bytes.write(to: store)

        let recovery = try #require(try MarfaModelContainer.open(path: store.path).recovery)
        // Part of the table came back, which is worth keeping.
        #expect(recovery.pendingMutationCount > 0)
        #expect(recovery.pendingMutationCount < 400)
        // And the part that did not has to be said, or the number above is a
        // lie an app will repeat.
        #expect(recovery.truncatedTables == ["pendingMutations"])

        // The sidecar is the durable half of that and carries it too.
        let file = try #require(recovery.sidecar, "no sidecar was written")
        #expect(try self.sidecar(at: file)["truncatedTables"] as? [String] == ["pendingMutations"])
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

    /// The one exit from the fail-safe that could still lose the data.
    ///
    /// Everything else here is arranged so that a failure leaves the store
    /// where it was. Once the rename has happened that is no longer possible:
    /// the queue, the dead letters, the cursor and the blob bytes are in a
    /// directory whose name only this call knows, so an open that returns the
    /// container's own error takes the address with it and the app is left
    /// looking at a store that is simply missing.
    @Test("a rebuild that fails after the quarantine still says where the old store went")
    func aFailedRebuildNamesTheQuarantine() throws {
        let directory = makeDirectory()
        let path = directory.appendingPathComponent("store.sqlite").path
        try seedStore(at: path, models: Alien.models)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }

        var thrown: Error?
        do {
            _ = try MarfaModelContainer.open(
                path: path,
                fileManager: SealsAfterMovingTheStore(sealingAfter: "store.sqlite")
            )
        } catch {
            thrown = error
        }

        let error = try #require(
            thrown as? LocalStoreError,
            "the rebuild reported \(String(describing: thrown)) rather than a storage error"
        )
        guard case .storeRebuildFailed(let quarantine, _) = error else {
            Issue.record("the failure did not name the quarantine directory: \(error)")
            return
        }
        // The name is only worth having if it leads to the rows.
        let salvage = try QuarantinedStoreReader.read(
            storeAt: quarantine.appendingPathComponent("store.sqlite")
        )
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
