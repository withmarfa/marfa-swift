import Testing
import Foundation
@testable import MarfaSDK
@_spi(MarfaSDKTestSupport) import MarfaSDK
@testable import MarfaSDKTestSupport
import SwiftData

/// The rows the fixture store holds, and the assertions against them.
///
/// One list, used by the writer and by both readers, so a regenerated fixture
/// and the checks on it cannot drift apart.
private enum SeededRows {
    static let itemId = "019eb100-0000-7000-8000-000000000001"
    static let itemType = "core.note"
    static let itemBody = "a row written by the shipped schema"
    static let edgeId = "019eb100-0000-7000-8000-000000000002"
    static let edgeType = "references"
    static let edgeTarget = "019eb100-0000-7000-8000-000000000003"
    static let metadataTag = "fixture"
    static let pendingId = "019eb100-0000-7000-8000-000000000004"
    static let pendingLocalId = "019eb100-0000-7000-8000-000000000005"
    static let droppedId = "019eb100-0000-7000-8000-000000000006"
    static let droppedLocalId = "019eb100-0000-7000-8000-000000000007"
    static let cursorKey = "last_event_id"
    static let cursorValue = "evt-42"
    static let blobHash = "sha256:cafebabe"
    static let blobMimeType = "image/png"
    /// Four bytes, and the size is the point. `PendingBlobModel.data` carries
    /// `@Attribute(.externalStorage)`, so a large blob is written to a file
    /// under `.store_SUPPORT/` instead of into the row — and a fixture whose
    /// bytes live outside `store.sqlite` would be incomplete the moment only
    /// the one file is committed. Small enough to stay inline keeps the
    /// fixture a single file.
    static let blobBytes = Data([0x89, 0x50, 0x4E, 0x47])
    static let stamp = "2026-09-02T07:00:00.000Z"

    /// Writes one row of every model in the schema.
    static func seed(into context: ModelContext) throws {
        let item = MarfaItemModel()
        item.id = itemId
        item.type = itemType
        item.stateRaw = ItemState.active.rawValue
        item.propertiesData = Data(#"{"body":"\#(itemBody)"}"#.utf8)
        item.source = "fixture"
        item.tierRaw = Tier.feed.rawValue
        item.version = 1
        item.schemaVersion = 1
        item.createdAt = stamp
        item.updatedAt = stamp
        item.timestamp = stamp
        context.insert(item)

        let metadata = MarfaMetadataModel()
        metadata.itemId = itemId
        metadata.tagsData = Data(#"["\#(metadataTag)"]"#.utf8)
        metadata.item = item
        context.insert(metadata)

        let edge = MarfaEdgeModel()
        edge.id = edgeId
        edge.sourceId = itemId
        edge.targetId = edgeTarget
        edge.edgeType = edgeType
        edge.createdAt = stamp
        edge.updatedAt = stamp
        context.insert(edge)

        let pending = PendingMutationModel()
        pending.id = pendingId
        pending.kindRaw = MutationKind.updateItem.rawValue
        pending.payloadJson = #"{"id":"\#(pendingLocalId)"}"#
        pending.localId = pendingLocalId
        pending.createdAt = stamp
        pending.attemptCount = 2
        pending.lastError = "code=network_error status=0 message=offline"
        pending.stateRaw = PendingMutationState.pending.rawValue
        context.insert(pending)

        let dropped = DroppedMutationModel()
        dropped.id = droppedId
        dropped.kindRaw = MutationKind.deleteItem.rawValue
        dropped.payloadJson = #"{"id":"\#(droppedLocalId)"}"#
        dropped.localId = droppedLocalId
        dropped.enqueuedAt = stamp
        dropped.droppedAt = stamp
        dropped.attemptCount = 1
        dropped.errorStatus = 404
        dropped.errorCode = "not_found"
        dropped.errorMessage = "gone"
        context.insert(dropped)

        let cursor = SyncStateModel()
        cursor.key = cursorKey
        cursor.value = cursorValue
        context.insert(cursor)

        let blob = PendingBlobModel()
        blob.contentHash = blobHash
        blob.data = blobBytes
        blob.mimeType = blobMimeType
        context.insert(blob)

        try context.save()
    }

    /// Every row, checked. Shared by the test and by the regeneration suite,
    /// which verifies what it wrote rather than trusting the write.
    static func assertAllRowsSurvived(in context: ModelContext) throws {
        let items = try context.fetch(FetchDescriptor<MarfaItemModel>())
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.id == itemId)
        #expect(item.type == itemType)
        #expect(item.state == .active)
        #expect(item.properties["body"] == .string(itemBody))

        let metadata = try context.fetch(FetchDescriptor<MarfaMetadataModel>())
        #expect(metadata.count == 1)
        let meta = try #require(metadata.first)
        #expect(meta.itemId == itemId)
        #expect(meta.tags == [metadataTag])
        // The relationship, not just the two rows: a migration that keeps both
        // tables and drops the link between them is a failure this catches.
        #expect(meta.item?.id == itemId)

        let edges = try context.fetch(FetchDescriptor<MarfaEdgeModel>())
        #expect(edges.count == 1)
        let edge = try #require(edges.first)
        #expect(edge.id == edgeId)
        #expect(edge.sourceId == itemId)
        #expect(edge.targetId == edgeTarget)
        #expect(edge.edgeType == edgeType)

        // The four below hold state that exists nowhere else. An item or an
        // edge can be fetched again from the server; a queued write, the bytes
        // behind it, the record of one the server refused, and the cursor
        // saying what this device has already seen cannot.
        let pending = try context.fetch(FetchDescriptor<PendingMutationModel>())
        #expect(pending.count == 1)
        let queued = try #require(pending.first)
        #expect(queued.id == pendingId)
        #expect(queued.localId == pendingLocalId)
        #expect(queued.kind == .updateItem)
        #expect(queued.attemptCount == 2)
        #expect(queued.state == .pending)

        let dropped = try context.fetch(FetchDescriptor<DroppedMutationModel>())
        #expect(dropped.count == 1)
        let deadLetter = try #require(dropped.first)
        #expect(deadLetter.id == droppedId)
        #expect(deadLetter.localId == droppedLocalId)
        #expect(deadLetter.kind == .deleteItem)
        #expect(deadLetter.errorStatus == 404)
        #expect(deadLetter.errorCode == "not_found")

        let syncState = try context.fetch(FetchDescriptor<SyncStateModel>())
        #expect(syncState.count == 1)
        let cursor = try #require(syncState.first)
        #expect(cursor.key == cursorKey)
        // A lost cursor is not a lost row: the device resumes the event stream
        // from the beginning, or from nothing, depending on what replaced it.
        #expect(cursor.value == cursorValue)

        let blobs = try context.fetch(FetchDescriptor<PendingBlobModel>())
        #expect(blobs.count == 1)
        let blob = try #require(blobs.first)
        #expect(blob.contentHash == blobHash)
        #expect(blob.mimeType == blobMimeType)
        #expect(blob.data == blobBytes)
    }
}

/// Where the fixture lives, for reading and for rewriting.
private enum FixturePaths {
    static let subdirectory = "Fixtures/ShippedStore"
    static let storeBaseName = "store"
    static let storeExtension = "sqlite"
    static var storeFileName: String { "\(storeBaseName).\(storeExtension)" }
    static let provenanceFileName = "generated-from.txt"

    /// SQLite writes a `-wal` and a `-shm` beside a store it has open, and
    /// Core Data adds `.store_SUPPORT/` for externally-stored attributes.
    /// None is committed, so regeneration checks each one is empty and clears
    /// it rather than leaving the fixture spread across four paths.
    static let uncommittedSiblings = ["\(storeFileName)-wal", "\(storeFileName)-shm"]
    static let supportDirectoryName = ".store_SUPPORT"

    /// The bundled copy, read by the test.
    static var bundledStore: URL? {
        Bundle.module.url(
            forResource: storeBaseName,
            withExtension: storeExtension,
            subdirectory: subdirectory
        )
    }

    /// The source-tree copy, written by regeneration. `#filePath` rather than
    /// the bundle, because a rewrite has to land in the repository rather than
    /// in a build directory.
    static var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(subdirectory, isDirectory: true)
    }
}

/// A store written by a shipped build has to keep opening as the schema moves.
///
/// `Tests/MarfaSDKTests/Fixtures/ShippedStore/README.md` explains what this
/// guards, what a failure means, and how to regenerate the fixture.
@Suite("A store written by the shipped schema opens under the current one")
struct ShippedStoreFixtureTests {

    /// Copies the committed fixture somewhere writable. Opening a store
    /// migrates it in place, so the checked-in copy must never be the one
    /// under test.
    private func stagedCopy(of source: URL) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("marfa-shipped-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staged = root.appendingPathComponent(FixturePaths.storeFileName)
        try FileManager.default.copyItem(at: source, to: staged)
        return staged
    }

    @Test("every row a shipped store holds is still there after it is opened")
    func shippedStoreOpensIntact() throws {
        // Named explicitly, because a fixture missing from the bundle would
        // otherwise arrive as an empty store and read as a schema break.
        let source = try #require(
            FixturePaths.bundledStore,
            "the store fixture is not in the test bundle"
        )
        let staged = try stagedCopy(of: source)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }

        let before = try FileManager.default.attributesOfItem(atPath: staged.path)
        let container = try MarfaModelContainer.make(path: staged.path)
        let after = try FileManager.default.attributesOfItem(atPath: staged.path)

        // A schema break does not throw. `MarfaModelContainer.make` answers a
        // store it cannot open by deleting it and building a fresh one, so the
        // failure would otherwise arrive as a set of rows that are mysteriously
        // zero. Say what happened instead: the file under this path is not the
        // file that was staged.
        let sizeChanged = (before[.size] as? Int) != (after[.size] as? Int)
        let dateChanged = (before[.modificationDate] as? Date) != (after[.modificationDate] as? Date)
        if sizeChanged || dateChanged {
            Issue.record(
                """
                The container could not open the fixture and replaced it: a model \
                changed shape, so every row below is gone. On a device this is \
                silent, and it costs the mutation queue, the pending blob bytes, \
                the dropped-mutation log and the event cursor. See \
                Fixtures/ShippedStore/README.md.
                """
            )
        }

        try SeededRows.assertAllRowsSurvived(in: ModelContext(container))
    }

    /// The cheap half of the same rule, and unchecked until now.
    ///
    /// A new *value* in a string column is free where a new column is fatal,
    /// and that asymmetry is the whole reason ``PendingMutationState`` is the
    /// place to extend the queue's lifecycle. It only holds if SwiftData really
    /// does store the column opaquely, so this writes a value no compiled case
    /// knows and reads it back.
    @Test("a stateRaw value the current build has no case for round-trips and reads as pending")
    func unknownStateValueRoundTrips() async throws {
        let (_, queue, container) = try await MarfaSDKTest.makeInMemoryStorePair()
        try await queue.enqueueDeleteItem(id: "server-unknown-state")

        let context = ModelContext(container)
        let stored = try #require(try context.fetch(FetchDescriptor<PendingMutationModel>()).first)
        stored.stateRaw = "quiesced"
        try context.save()

        let reread = try #require(try ModelContext(container)
            .fetch(FetchDescriptor<PendingMutationModel>()).first)
        // The column keeps what it was given — no truncation, no rejection.
        #expect(reread.stateRaw == "quiesced")
        // And the typed accessor falls back rather than trapping, which is what
        // makes the row replayable on a build that has never heard of the case.
        #expect(reread.state == .pending)
    }
}

/// Rewrites the fixture, verifies what it wrote, and records where it came
/// from.
///
///     MARFA_REGENERATE_STORE_FIXTURE=1 swift test --filter RegenerateTheShippedStoreFixture
///
/// Run it from the commit whose schema the fixture should pin. The commit is
/// written to `generated-from.txt` rather than typed into the README, so the
/// provenance cannot drift from the file it describes.
@Suite(
    "Regenerate the shipped-store fixture",
    .enabled(
        if: ProcessInfo.processInfo.environment["MARFA_REGENERATE_STORE_FIXTURE"] == "1",
        "set MARFA_REGENERATE_STORE_FIXTURE=1 to rewrite the committed store fixture"
    )
)
struct RegenerateTheShippedStoreFixture {

    private func currentCommit(in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "rev-parse", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("write a fresh store, verify it, and record the commit it pins")
    func regenerate() throws {
        let directory = FixturePaths.sourceDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = directory.appendingPathComponent(FixturePaths.storeFileName)

        for name in [FixturePaths.storeFileName] + FixturePaths.uncommittedSiblings {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(FixturePaths.supportDirectoryName)
        )

        // Scoped so the container is released, and the store closed and
        // checkpointed, before the files beside it are judged.
        do {
            let container = try MarfaModelContainer.make(path: store.path)
            try SeededRows.seed(into: ModelContext(container))
        }

        // A non-empty `-wal` means the close did not checkpoint and the store
        // file alone is not the whole store. Removing it would silently drop
        // whatever it holds, so say so instead.
        for sibling in FixturePaths.uncommittedSiblings {
            let url = directory.appendingPathComponent(sibling)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            if sibling.hasSuffix("-wal"), let size, size > 0 {
                Issue.record("\(sibling) is \(size) bytes: the store did not checkpoint on close, so store.sqlite alone is incomplete")
            }
            try? FileManager.default.removeItem(at: url)
        }

        // Externally-stored attributes land here. Empty is the expected state,
        // because the seeded blob is small enough to stay inline; anything in
        // it means the fixture's data is no longer one file.
        let support = directory.appendingPathComponent(FixturePaths.supportDirectoryName)
        let external = (try? FileManager.default
            .subpathsOfDirectory(atPath: support.path)
            .filter { !$0.hasSuffix("_EXTERNAL_DATA") }) ?? []
        if !external.isEmpty {
            Issue.record("\(FixturePaths.supportDirectoryName) holds \(external): the fixture is no longer a single file")
        }
        try? FileManager.default.removeItem(at: support)

        // What is left is what gets committed.
        let produced = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0 != "README.md" && $0 != FixturePaths.provenanceFileName }
            .sorted()
        #expect(produced == [FixturePaths.storeFileName])

        // Verify the file rather than the write: reopen the committed artifact
        // the way the test will, from a copy, so the fixture directory is left
        // exactly as it will be committed.
        let checkRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("marfa-regen-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: checkRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: checkRoot) }
        let copy = checkRoot.appendingPathComponent(FixturePaths.storeFileName)
        try FileManager.default.copyItem(at: store, to: copy)
        try SeededRows.assertAllRowsSurvived(in: ModelContext(try MarfaModelContainer.make(path: copy.path)))

        let commit = try currentCommit(in: directory)
        #expect(!commit.isEmpty, "could not read the current commit")
        try "\(commit)\n".write(
            to: directory.appendingPathComponent(FixturePaths.provenanceFileName),
            atomically: true,
            encoding: .utf8
        )
        print("regenerated \(FixturePaths.storeFileName) at \(commit)")
    }
}
